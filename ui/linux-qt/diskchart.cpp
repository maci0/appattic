#include "diskchart.h"

#include "finding.h"
#include "uistyle.h"

#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QToolTip>
#include <QtMath>

#include <algorithm>
#include <cmath>

QColor diskChartColor(int index) {
    static const int kHue[] = {211, 8, 48, 145, 280, 32, 190, 330, 90, 250};
    const int hue = kHue[index % 10];
    const int sat = 160 - (index / 10) * 20;
    return QColor::fromHsv(hue, qBound(80, sat, 180), 220);
}

DiskChart::DiskChart(QWidget *parent) : QWidget(parent) {
    setMouseTracking(true);
    setMinimumSize(220, 220);
    setAutoFillBackground(true);
}

void DiskChart::setRoot(DiskNode *node) {
    m_root = node;
    m_view = node;
    m_hover = nullptr;
    update();
}

void DiskChart::setView(DiskNode *node) {
    if (!node) return;
    m_view = node;
    m_hover = nullptr;
    update();
}

void DiskChart::goUp() {
    if (m_view && m_view->parent) {
        m_view = m_view->parent;
        m_hover = nullptr;
        update();
    }
}

void DiskChart::setAllocated(bool on) {
    if (m_allocated == on) return;
    m_allocated = on;
    update();
}

void DiskChart::setMode(Mode mode) {
    if (m_mode == mode) return;
    m_mode = mode;
    update();
}

QSize DiskChart::minimumSizeHint() const {
    return QSize(260, 260);
}

QColor DiskChart::colorFor(const DiskNode *node, int index) const {
    Q_UNUSED(node);
    return diskChartColor(index);
}

void DiskChart::paintEvent(QPaintEvent *) {
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing);
    const QRect box = rect().adjusted(8, 8, -8, -8);
    m_hits.clear();
    if (!m_view) {
        p.setPen(palette().placeholderText().color());
        p.drawText(box, Qt::AlignCenter, QStringLiteral("Scan a folder to see usage."));
        return;
    }
    if (m_mode == Mode::Rings) paintRings(p, box);
    else paintTreemap(p, box);
}

void DiskChart::paintRings(QPainter &p, const QRect &box) {
    const QPointF c = box.center();
    const qreal maxR = qMin(box.width(), box.height()) / 2.0 - 4;
    const int rings = 4;
    const qreal inner = maxR * 0.18;
    const qreal ringW = (maxR - inner) / rings;

    auto metric = [this](const DiskNode *n) { return qMax(qint64(0), n->metric(m_allocated)); };

    struct Slice {
        DiskNode *node;
        int depth;
        qreal start;
        qreal span;
        int colorIndex;
    };
    QVector<Slice> slices;
    slices.append({m_view, 0, 0, 360.0, 0});

    auto addChildren = [&](auto &&self, DiskNode *parent, int depth, qreal start, qreal span, int colorBase) -> void {
        if (depth >= rings) return;
        qint64 tot = 0;
        for (DiskNode *ch : parent->children) tot += metric(ch);
        if (tot <= 0) return;
        qreal a = start;
        int i = 0;
        for (DiskNode *ch : parent->children) {
            const qint64 m = metric(ch);
            if (m <= 0) continue;
            qreal s = span * (qreal(m) / qreal(tot));
            if (s < 0.15) continue;
            slices.append({ch, depth, a, s, colorBase + i});
            self(self, ch, depth + 1, a, s, colorBase + i + 3);
            a += s;
            ++i;
        }
    };
    addChildren(addChildren, m_view, 1, 90.0, 360.0, 0);

    for (const Slice &sl : slices) {
        const qreal r0 = sl.depth == 0 ? 0 : inner + (sl.depth - 1) * ringW;
        const qreal r1 = sl.depth == 0 ? inner : inner + sl.depth * ringW;
        QPainterPath path;
        if (sl.depth == 0) {
            path.addEllipse(c, inner - 2, inner - 2);
        } else {
            const qreal start = sl.start;
            const qreal span = sl.span;
            QRectF outer(c.x() - r1, c.y() - r1, r1 * 2, r1 * 2);
            QRectF inn(c.x() - r0, c.y() - r0, r0 * 2, r0 * 2);
            path.arcMoveTo(outer, start);
            path.arcTo(outer, start, span);
            path.arcTo(inn, start + span, -span);
            path.closeSubpath();
        }
        QColor col = sl.depth == 0
            ? palette().button().color()
            : colorFor(sl.node, sl.colorIndex);
        if (m_hover == sl.node) col = col.lighter(118);
        p.setBrush(col);
        p.setPen(QPen(palette().window().color(), 1));
        p.drawPath(path);
        Hit hit;
        hit.node = sl.node;
        hit.ring = true;
        hit.inner = r0;
        hit.outer = r1;
        hit.start = sl.start;
        hit.span = sl.span;
        m_hits.append(hit);
    }

    p.setPen(palette().text().color());
    p.setFont(aaTitleFont());
    const QString label = m_view->name;
    const QRectF hole(c.x() - inner + 4, c.y() - 16, (inner - 4) * 2, 32);
    p.drawText(hole, Qt::AlignCenter | Qt::TextWordWrap, label);
}

void DiskChart::squarify(
    const QVector<DiskNode *> &nodes,
    qint64 total,
    const QRectF &bounds,
    QVector<QRectF> *out
) const {
    out->clear();
    out->reserve(nodes.size());
    if (nodes.isEmpty() || total <= 0 || bounds.width() <= 1 || bounds.height() <= 1) {
        for (int i = 0; i < nodes.size(); ++i) out->append(QRectF());
        return;
    }
    QVector<qint64> sizes;
    sizes.reserve(nodes.size());
    qint64 sum = 0;
    for (DiskNode *n : nodes) {
        const qint64 m = qMax(qint64(0), n->metric(m_allocated));
        sizes.append(m);
        sum += m;
    }
    if (sum <= 0) {
        for (int i = 0; i < nodes.size(); ++i) out->append(QRectF());
        return;
    }
    const qreal scale = (bounds.width() * bounds.height()) / qreal(sum);
    QVector<qreal> areas;
    for (qint64 s : sizes) areas.append(qreal(s) * scale);

    qreal x = bounds.x();
    qreal y = bounds.y();
    qreal w = bounds.width();
    qreal h = bounds.height();
    int i = 0;
    while (i < areas.size()) {
        const bool vertical = w >= h;
        const qreal shortSide = vertical ? h : w;
        if (shortSide <= 0.5) break;
        int rowEnd = i;
        qreal rowArea = 0;
        qreal bestWorst = 1e12;
        for (int j = i; j < areas.size(); ++j) {
            rowArea += areas[j];
            const qreal rowOther = rowArea / shortSide;
            qreal worstNow = 0;
            qreal acc = 0;
            for (int k = i; k <= j; ++k) {
                const qreal len = shortSide * (areas[k] / rowArea);
                const qreal r = qMax(rowOther / len, len / rowOther);
                worstNow = qMax(worstNow, r);
                acc += areas[k];
            }
            Q_UNUSED(acc);
            if (j > i && worstNow > bestWorst) {
                rowArea -= areas[j];
                break;
            }
            bestWorst = worstNow;
            rowEnd = j;
        }
        const qreal rowOther = rowArea / shortSide;
        qreal cursor = vertical ? y : x;
        for (int k = i; k <= rowEnd; ++k) {
            const qreal len = shortSide * (areas[k] / rowArea);
            QRectF r;
            if (vertical) {
                r = QRectF(x, cursor, rowOther, len);
                cursor += len;
            } else {
                r = QRectF(cursor, y, len, rowOther);
                cursor += len;
            }
            out->append(r.adjusted(1, 1, -1, -1));
        }
        if (vertical) {
            x += rowOther;
            w -= rowOther;
        } else {
            y += rowOther;
            h -= rowOther;
        }
        i = rowEnd + 1;
    }
    while (out->size() < nodes.size()) out->append(QRectF());
}

void DiskChart::paintTreemap(QPainter &p, const QRect &box) {
    QVector<DiskNode *> kids;
    qint64 tot = 0;
    for (DiskNode *ch : m_view->children) {
        const qint64 m = ch->metric(m_allocated);
        if (m <= 0) continue;
        kids.append(ch);
        tot += m;
    }
    QVector<QRectF> rects;
    squarify(kids, tot, QRectF(box), &rects);
    for (int i = 0; i < kids.size() && i < rects.size(); ++i) {
        const QRectF r = rects[i];
        if (r.width() < 2 || r.height() < 2) continue;
        QColor col = colorFor(kids[i], i);
        if (m_hover == kids[i]) col = col.lighter(118);
        p.setBrush(col);
        p.setPen(QPen(palette().window().color(), 1));
        p.drawRect(r);
        Hit hit;
        hit.node = kids[i];
        hit.rect = r;
        hit.ring = false;
        m_hits.append(hit);
        if (r.width() > 48 && r.height() > 22) {
            p.setPen(QColor(255, 255, 255));
            p.setFont(aaTitleFont());
            p.drawText(r.adjusted(4, 4, -4, -4), Qt::AlignTop | Qt::AlignLeft | Qt::TextWordWrap, kids[i]->name);
            p.setFont(aaNumericFont());
            p.drawText(
                r.adjusted(4, 20, -4, -4),
                Qt::AlignTop | Qt::AlignLeft,
                humanSize(kids[i]->metric(m_allocated))
            );
        }
    }
    if (kids.isEmpty()) {
        p.setPen(palette().placeholderText().color());
        p.drawText(box, Qt::AlignCenter, QStringLiteral("Empty folder"));
    }
}

DiskNode *DiskChart::hitAt(const QPoint &pos) const {
    if (m_mode == Mode::Treemap) {
        for (const Hit &h : m_hits) {
            if (!h.ring && h.rect.contains(pos)) return h.node;
        }
        return nullptr;
    }
    const QRect box = rect().adjusted(8, 8, -8, -8);
    const QPointF c = box.center();
    const qreal dx = pos.x() - c.x();
    const qreal dy = pos.y() - c.y();
    const qreal r = std::sqrt(dx * dx + dy * dy);
    qreal ang = std::atan2(-dy, dx) * 180.0 / 3.14159265358979323846;
    if (ang < 0) ang += 360.0;
    DiskNode *best = nullptr;
    qreal bestOuter = -1;
    for (const Hit &h : m_hits) {
        if (!h.ring) continue;
        if (r < h.inner || r > h.outer) continue;
        if (h.span >= 359.0) {
            if (h.outer > bestOuter) {
                best = h.node;
                bestOuter = h.outer;
            }
            continue;
        }
        qreal a = std::fmod(ang - h.start + 360.0, 360.0);
        if (a <= h.span && h.outer > bestOuter) {
            best = h.node;
            bestOuter = h.outer;
        }
    }
    return best;
}

void DiskChart::mousePressEvent(QMouseEvent *event) {
    if (event->button() != Qt::LeftButton) return;
    DiskNode *n = hitAt(event->pos());
    if (!n) return;
    if (n == m_view && n->parent) {
        m_view = n->parent;
        update();
        emit nodeActivated(m_view);
        return;
    }
    if (n->isDir && n != m_view) {
        m_view = n;
        update();
    }
    emit nodeActivated(n);
}

void DiskChart::mouseMoveEvent(QMouseEvent *event) {
    DiskNode *n = hitAt(event->pos());
    if (n != m_hover) {
        m_hover = n;
        update();
        if (n) {
            const QString tip = n->name + QLatin1Char('\n')
                + humanSize(n->metric(m_allocated)) + QLatin1Char('\n')
                + n->path;
            QToolTip::showText(event->globalPosition().toPoint(), tip, this);
            emit nodeHovered(n);
        } else {
            QToolTip::hideText();
        }
    }
}

void DiskChart::leaveEvent(QEvent *) {
    if (m_hover) {
        m_hover = nullptr;
        update();
    }
    QToolTip::hideText();
}
