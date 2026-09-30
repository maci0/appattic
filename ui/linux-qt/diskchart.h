#ifndef APPATTIC_DISKCHART_H
#define APPATTIC_DISKCHART_H

#include "diskusage.h"

#include <QColor>
#include <QString>
#include <QVector>
#include <QWidget>

class DiskChart : public QWidget {
    Q_OBJECT
public:
    enum class Mode { Rings, Treemap };

    explicit DiskChart(QWidget *parent = nullptr);

    void setRoot(DiskNode *node);
    void setView(DiskNode *node);
    void goUp();
    void setAllocated(bool on);
    void setMode(Mode mode);
    DiskNode *viewRoot() const { return m_view; }

signals:
    void nodeActivated(DiskNode *node);
    /// Fires when the keyboard cursor moves, so the page can mirror it into
    /// the tree (which carries the same rows and is the screen-reader path).
    void nodeFocused(DiskNode *node);

protected:
    void paintEvent(QPaintEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void leaveEvent(QEvent *event) override;
    void keyPressEvent(QKeyEvent *event) override;
    void focusInEvent(QFocusEvent *event) override;
    void focusOutEvent(QFocusEvent *event) override;
    QSize minimumSizeHint() const override;

private:
    struct Hit {
        DiskNode *node = nullptr;
        QRectF rect;
        qreal inner = 0;
        qreal outer = 0;
        qreal start = 0;
        qreal span = 0;
        bool ring = false;
    };

    void paintRings(class QPainter &p, const QRect &box);
    void paintTreemap(class QPainter &p, const QRect &box);
    void squarify(
        const QVector<DiskNode *> &nodes,
        qint64 total,
        const QRectF &bounds,
        QVector<QRectF> *out
    ) const;
    DiskNode *hitAt(const QPoint &pos) const;

    /// Nodes the keyboard cursor can land on, in paint order: the folder the
    /// chart is showing, then the children drawn inside it.
    QVector<DiskNode *> navigableNodes() const;
    /// Move the cursor by `delta` over those nodes, wrapping. True when the
    /// cursor moved, so the caller repaints only when it has to.
    bool moveCursor(int delta);
    /// One line naming the node under the cursor: name, size, share of the
    /// view. It is the accessible value, and what focus announces on entry.
    QString cursorDescription() const;
    /// Draw the focus ring on the node under the cursor. The chart paints its
    /// own cells, so no style draws an item highlight and a moving cursor
    /// would otherwise be invisible.
    void paintCursorRing(QPainter &p) const;
    /// Name and size of the chart's current folder, for assistive tech.
    QString viewDescription() const;
    /// Push the folder under the cursor into the accessible description and
    /// fire a description-changed event, so a screen reader announces the
    /// folder the arrow keys just moved to. Safe with no bridge attached.
    void refreshAccessibleText();

    DiskNode *m_root = nullptr;
    DiskNode *m_view = nullptr;
    DiskNode *m_hover = nullptr;
    DiskNode *m_cursor = nullptr;
    /// The static key hint, kept so the live folder can be appended to it
    /// without losing the help on every cursor move.
    QString m_helpText;
    bool m_allocated = true;
    Mode m_mode = Mode::Rings;
    QVector<Hit> m_hits;
};

#endif
