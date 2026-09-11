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
    Mode mode() const { return m_mode; }
    DiskNode *viewRoot() const { return m_view; }

signals:
    void nodeActivated(DiskNode *node);
    void nodeHovered(DiskNode *node);

protected:
    void paintEvent(QPaintEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void leaveEvent(QEvent *event) override;
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
    QColor colorFor(const DiskNode *node, int index) const;
    DiskNode *hitAt(const QPoint &pos) const;

    DiskNode *m_root = nullptr;
    DiskNode *m_view = nullptr;
    DiskNode *m_hover = nullptr;
    bool m_allocated = true;
    Mode m_mode = Mode::Rings;
    QVector<Hit> m_hits;
};

QColor diskChartColor(int index);

#endif
