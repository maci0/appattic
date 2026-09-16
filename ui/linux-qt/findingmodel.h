#pragma once

#include <QAbstractItemModel>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVector>

#include <functional>
#include <utility>

#include "finding.h"

/// Lazy table model over one page's findings.
///
/// The QTreeWidget built a heap item per row and per cell before the first
/// paint: 2000 rows cost 20-40 ms on every page switch or changed rescan. Here
/// a fill is a vector swap plus one model reset, and cell text is produced on
/// demand for the rows the view actually paints.
///
/// The window owns every label, colour and mark set; it passes them in as
/// `CellFn`. The model owns only the row list, so it needs no Qt meta-object
/// and no mutable display state.
class FindingModel : public QAbstractItemModel {
public:
    /// (finding, child name or empty, column, role) -> cell value.
    using CellFn = std::function<QVariant(const Finding &, const QString &, int, int)>;
    /// A check state flipped in the view.
    using ToggleFn = std::function<void(const Finding &, const QString &, bool)>;

    explicit FindingModel(QObject *parent = nullptr) : QAbstractItemModel(parent) {}

    /// One reset for headers, rows and callbacks together: a fill repaints once.
    void setContent(
        QStringList headers,
        int rightAlignedColumn,
        QString headerTip,
        bool children,
        QVector<Finding> rows,
        CellFn cell,
        ToggleFn toggle
    ) {
        beginResetModel();
        m_headers = std::move(headers);
        m_rightAligned = rightAlignedColumn;
        m_headerTip = std::move(headerTip);
        m_children = children;
        m_rows = std::move(rows);
        m_cell = std::move(cell);
        m_toggle = std::move(toggle);
        // Qt 6 indexes carry one pointer-sized word and alias internalId with
        // internalPointer, so the two levels are described by explicit nodes
        // instead of by arithmetic on that word.
        m_topNodes.resize(m_rows.size());
        for (int i = 0; i < m_rows.size(); ++i) m_topNodes[i] = Node{i, -1};
        m_childStart.clear();
        m_childNodes.clear();
        if (m_children) {
            for (int i = 0; i < m_rows.size(); ++i) {
                m_childStart.push_back(m_childNodes.size());
                const QStringList &kids = m_rows.at(i).children;
                for (int k = 0; k < kids.size(); ++k) m_childNodes.push_back(Node{k, i});
            }
            m_childStart.push_back(m_childNodes.size());
        }
        endResetModel();
    }

    const QVector<Finding> &rows() const { return m_rows; }

    int rowOfUid(const QString &uid) const {
        for (int i = 0; i < m_rows.size(); ++i) {
            if (m_rows.at(i).uid() == uid) return i;
        }
        return -1;
    }

    /// Empty index when the row (or the child) is not in the current page.
    QModelIndex indexOfUid(const QString &uid, const QString &child = QString()) const {
        const int row = rowOfUid(uid);
        if (row < 0) return {};
        const QModelIndex parent = index(row, 0, QModelIndex());
        if (child.isEmpty()) return parent;
        const QStringList &kids = m_rows.at(row).children;
        for (int k = 0; k < kids.size(); ++k) {
            if (kids.at(k) == child) return index(k, 0, parent);
        }
        return {};
    }

    /// The cell text of one row changed: repaint it instead of the whole table.
    void refreshUid(const QString &uid, const QString &child = QString()) {
        const QModelIndex idx = indexOfUid(uid, child);
        if (!idx.isValid()) return;
        emit dataChanged(idx, idx, {Qt::DisplayRole, Qt::CheckStateRole, Qt::ToolTipRole,
                                    Qt::ForegroundRole});
    }

    QModelIndex index(int row, int column, const QModelIndex &parent = QModelIndex()) const override {
        if (row < 0 || column < 0 || column >= m_headers.size()) return {};
        if (!parent.isValid()) {
            if (row >= m_rows.size()) return {};
            return createIndex(row, column, &m_topNodes.at(row));
        }
        const Node *p = nodeOf(parent);
        if (!p || p->parent >= 0 || p->row >= m_rows.size()) return {};
        if (row >= m_rows.at(p->row).children.size()) return {};
        return createIndex(row, column, &m_childNodes.at(m_childStart.at(p->row) + row));
    }

    QModelIndex parent(const QModelIndex &child) const override {
        const Node *n = nodeOf(child);
        if (!n || n->parent < 0) return {};
        return createIndex(n->parent, 0, &m_topNodes.at(n->parent));
    }

    int rowCount(const QModelIndex &parent = QModelIndex()) const override {
        if (!parent.isValid()) return m_rows.size();
        const Node *n = nodeOf(parent);
        if (!n || n->parent >= 0 || n->row >= m_rows.size()) return 0;
        return m_rows.at(n->row).children.size();
    }

    int columnCount(const QModelIndex & = QModelIndex()) const override { return m_headers.size(); }

    QVariant data(const QModelIndex &idx, int role) const override {
        const Node *n = nodeOf(idx);
        if (!n) return {};
        if (n->parent >= 0) {
            const Finding &f = m_rows.at(n->parent);
            if (n->row >= f.children.size()) return {};
            // A child row reports its parent's uid, as the QTreeWidget item did.
            if (role == Qt::UserRole) return f.uid();
            if (role == Qt::UserRole + 1) return f.children.at(n->row);
            if (!m_cell) return {};
            return m_cell(f, f.children.at(n->row), idx.column(), role);
        }
        if (n->row >= m_rows.size()) return {};
        const Finding &f = m_rows.at(n->row);
        if (role == Qt::UserRole) return f.uid();
        if (role == Qt::UserRole + 1) return QString();
        if (!m_cell) return {};
        return m_cell(f, QString(), idx.column(), role);
    }

    QVariant headerData(int section, Qt::Orientation orientation, int role) const override {
        if (orientation != Qt::Horizontal) return {};
        if (role == Qt::DisplayRole) {
            return section < m_headers.size() ? QVariant(m_headers.at(section)) : QVariant();
        }
        if (role == Qt::TextAlignmentRole && section == m_rightAligned) {
            return int(Qt::AlignRight | Qt::AlignVCenter);
        }
        if (role == Qt::ToolTipRole && section == 0) return m_headerTip;
        return {};
    }

    Qt::ItemFlags flags(const QModelIndex &idx) const override {
        const Node *n = nodeOf(idx);
        if (!n) return Qt::NoItemFlags;
        Qt::ItemFlags f = Qt::ItemIsEnabled | Qt::ItemIsSelectable;
        if (n->parent < 0 && idx.column() == 0 && data(idx, Qt::CheckStateRole).isValid()) {
            f |= Qt::ItemIsUserCheckable;
        }
        return f;
    }

    bool setData(const QModelIndex &idx, const QVariant &value, int role) override {
        if (role != Qt::CheckStateRole || idx.column() != 0) return false;
        const Node *n = nodeOf(idx);
        if (!n || n->parent >= 0 || n->row >= m_rows.size() || !m_toggle) return false;
        m_toggle(m_rows.at(n->row), QString(), value.toInt() == Qt::Checked);
        // Repaint even when the toggle was refused: the box snaps back.
        emit dataChanged(idx, idx, {Qt::CheckStateRole, Qt::DisplayRole, Qt::ToolTipRole});
        return true;
    }

private:
    /// Row bookkeeping: its own row, and its parent row (-1 at top level).
    struct Node {
        int row = 0;
        int parent = -1;
    };

    const Node *nodeOf(const QModelIndex &idx) const {
        if (!idx.isValid()) return nullptr;
        const void *ptr = idx.constInternalPointer();
        return ptr ? static_cast<const Node *>(ptr) : nullptr;
    }

    QStringList m_headers;
    int m_rightAligned = -1;
    QString m_headerTip;
    bool m_children = false;
    QVector<Finding> m_rows;
    QVector<Node> m_topNodes;
    QVector<Node> m_childNodes;
    QVector<int> m_childStart;
    CellFn m_cell;
    ToggleFn m_toggle;
};
