#include "diskchart.h"

#include "finding.h"
#include "uistyle.h"

#include <QAccessible>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QToolTip>

#include <algorithm>
#include <cmath>

// The hue cycle opens on the app accents (accent blue, remove red, review
// amber, keep green) so a chart reads as AppAttic rather than a stock rainbow,
// then adds distinct hues for deeper siblings. Value and saturation follow the
// window palette, so a dark window gets chart fills that sit with dark chrome
// instead of the same mid brightness light mode uses.
static const int kChartHue[] = {211, 8, 48, 145, 280, 32, 190, 330, 90, 250};
static const int kChartHueCount = 10;

static QColor diskChartColor(int index, bool dark) {
    const int hue = kChartHue[index % kChartHueCount];
    // Saturation and value are pulled back from where they started because the
    // cell name and its size are drawn on the fill in the body font, and that
    // is normal text, so it needs 4.5:1 (WCAG 1.4.3). At the old values no
    // black or white label cleared the bar on the mid-tone cells, and the
    // worst one measured 4.42:1 in light mode and 4.40:1 in dark. These land
    // the worst cell at 4.98:1 and 5.75:1, and the ten hues stay as distinct
    // from each other as they were.
    const int sat = qBound(80, 130 - (index / kChartHueCount) * 20, 180);
    return QColor::fromHsv(hue, dark ? sat / 2 : sat, dark ? 185 : 235);
}

// Relative luminance of a colour, the sRGB definition WCAG 1.4.3 contrast is
// built on. Not Qt's lightness: that is the HSL midpoint and it says nothing
// about how much light a colour actually reflects, so it is a poor predictor
// of the contrast a label drawn on it will have.
static double relativeLuminance(const QColor &c) {
    const auto chan = [](int v) {
        const double s = v / 255.0;
        return s <= 0.04045 ? s / 12.92 : std::pow((s + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * chan(c.red()) + 0.7152 * chan(c.green()) + 0.0722 * chan(c.blue());
}

static double contrastOn(const QColor &a, const QColor &b) {
    const double la = relativeLuminance(a);
    const double lb = relativeLuminance(b);
    const double hi = std::max(la, lb);
    const double lo = std::min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

// Cell labels need the better of black or white against the fill they land on.
// A fixed white is unreadable on a light-mode cell; a fixed black is unreadable
// on a dark-mode one. Picking by HSL lightness put dark text on fills that are
// too dark to read it, and the cell names failed 4.5:1 (WCAG 1.4.3): the worst
// light-mode cell measured 3.37:1. Choosing by measured contrast instead keeps
// the same two colours and no longer has a cell under the floor.
static QColor onChartColor(const QColor &fill) {
    const QColor dark(20, 20, 20);
    const QColor light(255, 255, 255);
    return contrastOn(dark, fill) >= contrastOn(light, fill) ? dark : light;
}

DiskChart::DiskChart(QWidget *parent) : QWidget(parent) {
    setMouseTracking(true);
    setMinimumSize(220, 220);
    setAutoFillBackground(true);
    // The chart is a QWidget painted by hand, so Qt gives it no focus and no
    // key handling: a keyboard user could not enter it at all, and a screen
    // reader never reached the sizes the rings and cells encode. It takes
    // focus like a list does and answers the list keys; the tree beside it
    // carries the same rows in a control assistive tech already reads.
    setFocusPolicy(Qt::StrongFocus);
    setAccessibleName(QStringLiteral("Disk usage chart"));
    m_helpText = QStringLiteral(
        "Arrow keys move between folders, Enter opens one, Backspace goes up. "
        "The folder list beside this chart shows the same folders with their sizes."
    );
    setAccessibleDescription(m_helpText);
}

void DiskChart::setRoot(DiskNode *node) {
    m_root = node;
    m_view = node;
    m_hover = nullptr;
    // The hits hold raw node pointers into the tree the caller is replacing,
    // and the repaint that would clear them has not run yet, so a mouse move
    // in between would hand a freed node to a tooltip or to the page.
    m_hits.clear();
    // Same for the keyboard cursor: a node from the tree being dropped would
    // be read, compared, and named by every key handler until the next one.
    m_cursor = nullptr;
    update();
}

void DiskChart::setView(DiskNode *node) {
    if (!node) return;
    m_view = node;
    m_hover = nullptr;
    // A cursor that pointed into the subtree just left behind is not a node of
    // the new view, so it starts again at the view's own centre.
    m_cursor = nullptr;
    update();
}

void DiskChart::goUp() {
    if (m_view && m_view->parent) {
        m_view = m_view->parent;
        m_hover = nullptr;
        m_cursor = nullptr;
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
    paintCursorRing(p);
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
        for (DiskNode *ch : parent->children) tot = addSatBytes(tot, metric(ch));
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
        const bool dark = palette().window().color().lightness() < 128;
        QColor col = sl.depth == 0
            ? palette().button().color()
            : diskChartColor(sl.colorIndex, dark);
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
        sum = addSatBytes(sum, m);
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
        // A node with no bytes of its own gets no area, and the row it would
        // open has rowArea 0, so areas[k] / rowArea is 0/0. The rectangle then
        // comes out NaN, which passes neither the `width() < 2` test in
        // paintTreemap nor the painter's clip, so the cell is drawn outside the
        // box instead of being left out. Give it an empty rect and move on.
        if (areas[i] <= 0) {
            out->append(QRectF());
            ++i;
            continue;
        }
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
            for (int k = i; k <= j; ++k) {
                const qreal len = shortSide * (areas[k] / rowArea);
                const qreal r = qMax(rowOther / len, len / rowOther);
                worstNow = qMax(worstNow, r);
            }
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
        tot = addSatBytes(tot, m);
    }
    QVector<QRectF> rects;
    squarify(kids, tot, QRectF(box), &rects);
    for (int i = 0; i < kids.size() && i < rects.size(); ++i) {
        const QRectF r = rects[i];
        if (r.width() < 2 || r.height() < 2) continue;
        const bool dark = palette().window().color().lightness() < 128;
        QColor col = diskChartColor(i, dark);
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
            p.setPen(onChartColor(col));
            p.setFont(aaTitleFont());
            p.drawText(r.adjusted(4, 4, -4, -4), Qt::AlignTop | Qt::AlignLeading | Qt::TextWordWrap, kids[i]->name);
            p.setFont(aaNumericFont());
            p.drawText(
                r.adjusted(4, 20, -4, -4),
                Qt::AlignTop | Qt::AlignLeading,
                humanSize(kids[i]->metric(m_allocated))
            );
        }
    }
    if (kids.isEmpty()) {
        p.setPen(palette().placeholderText().color());
        p.drawText(box, Qt::AlignCenter, QStringLiteral("Empty folder"));
    }
}

QVector<DiskNode *> DiskChart::navigableNodes() const {
    QVector<DiskNode *> out;
    if (!m_view) return out;
    // The folder the chart is showing comes first: in the rings it is the
    // centre disc, and in both modes it is what Up and Backspace return to.
    out.append(m_view);
    // Only children with a size are painted, so only those can be pointed at.
    for (DiskNode *ch : m_view->children) {
        if (qMax(qint64(0), ch->metric(m_allocated)) > 0) out.append(ch);
    }
    return out;
}

QString DiskChart::cursorDescription() const {
    if (!m_cursor) return QString();
    const qint64 bytes = qMax(qint64(0), m_cursor->metric(m_allocated));
    QString s = m_cursor->name;
    s += QStringLiteral(", ");
    s += humanSize(bytes);
    // The share is what the ring angle and the cell area encode visually, and
    // the size column alone does not say how much of the folder this is.
    const qint64 total = m_view ? qMax(qint64(0), m_view->metric(m_allocated)) : qint64(0);
    if (total > 0) {
        const int pct = qRound(100.0 * double(bytes) / double(total));
        s += QStringLiteral(", %1 percent of this folder").arg(pct);
    }
    if (m_cursor->isDir) s += QStringLiteral(", opens on Enter");
    return s;
}

QString DiskChart::viewDescription() const {
    if (!m_view) return QStringLiteral("No folder scanned yet.");
    return m_view->name + QStringLiteral(", ") + humanSize(m_view->metric(m_allocated));
}

bool DiskChart::moveCursor(int delta) {
    const QVector<DiskNode *> nodes = navigableNodes();
    if (nodes.isEmpty()) return false;
    int at = 0;
    for (int i = 0; i < nodes.size(); ++i) {
        if (nodes[i] == m_cursor) {
            at = i;
            break;
        }
    }
    const int n = nodes.size();
    at = ((at + delta) % n + n) % n;
    if (nodes[at] == m_cursor) return false;
    m_cursor = nodes[at];
    update();
    refreshAccessibleText();
    return true;
}

void DiskChart::paintCursorRing(QPainter &p) const {
    if (!hasFocus() || !m_cursor) return;
    for (const Hit &h : m_hits) {
        if (h.node != m_cursor) continue;
        const QRectF box = QRectF(rect()).adjusted(8, 8, -8, -8);
        const QColor accent = palette().color(QPalette::Highlight);
        // Two outlines: the window background, then the highlight colour on
        // top. The wide ring is the background rather than black or white so
        // it separates the cursor from a cell fill of any colour.
        const QColor behind = palette().window().color();
        p.save();
        p.setBrush(Qt::NoBrush);
        QPen wide(behind, 3.0);
        QPen thin(accent, 1.0);
        wide.setJoinStyle(Qt::RoundJoin);
        thin.setJoinStyle(Qt::RoundJoin);
        if (h.ring) {
            const qreal mid = (h.inner + h.outer) / 2.0;
            p.setPen(wide);
            p.drawEllipse(box.center(), mid, mid);
            p.setPen(thin);
            p.drawEllipse(box.center(), mid + 1.5, mid + 1.5);
        } else {
            const QRectF r = h.rect.adjusted(-1.5, -1.5, 1.5, 1.5);
            p.setPen(wide);
            p.drawRect(r);
            p.setPen(thin);
            p.drawRect(r.adjusted(-1.5, -1.5, 1.5, 1.5));
        }
        p.restore();
        return;
    }
}

void DiskChart::refreshAccessibleText() {
    const QString text = cursorDescription();
    // The widget-level description is what QAccessible::queryAccessibleInterface
    // falls back to when a bridge is not attached, and what a test (or a
    // screen reader reading the object) sees. Keep it current, prefixed by the
    // static help so the key hints are always there alongside the live folder.
    if (!text.isEmpty()) {
        setAccessibleDescription(m_helpText + QStringLiteral(" Currently: ") + text);
    }
    // QAccessible::updateAccessibility is a no-op with no bridge running, so
    // this costs nothing in a session with no screen reader attached.
    if (QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(this)) {
        iface->setText(QAccessible::Description, text);
    }
    QAccessibleEvent ev(this, QAccessible::DescriptionChanged);
    QAccessible::updateAccessibility(&ev);
}

void DiskChart::keyPressEvent(QKeyEvent *event) {
    if (navigableNodes().isEmpty()) {
        QWidget::keyPressEvent(event);
        return;
    }
    switch (event->key()) {
    case Qt::Key_Right:
    case Qt::Key_Down:
        if (moveCursor(1)) {
            emit nodeFocused(m_cursor);
            event->accept();
            return;
        }
        break;
    case Qt::Key_Left:
    case Qt::Key_Up:
        if (moveCursor(-1)) {
            emit nodeFocused(m_cursor);
            event->accept();
            return;
        }
        break;
    case Qt::Key_Home:
        moveCursor(0);
        emit nodeFocused(m_cursor);
        event->accept();
        return;
    case Qt::Key_End: {
        const QVector<DiskNode *> nodes = navigableNodes();
        moveCursor(nodes.size() - 1);
        emit nodeFocused(m_cursor);
        event->accept();
        return;
    }
    case Qt::Key_Return:
    case Qt::Key_Enter:
    case Qt::Key_Space:
        // The same drill-in a click on a folder does. The view node itself has
        // nowhere to go in, so a click on the centre disc went up a level; the
        // Backspace case below is that path from the keyboard.
        if (m_cursor && m_cursor != m_view && m_cursor->isDir) {
            m_view = m_cursor;
            m_cursor = nullptr;
            m_hover = nullptr;
            update();
            emit nodeActivated(m_view);
            emit nodeFocused(m_view);
            refreshAccessibleText();
            event->accept();
            return;
        }
        break;
    case Qt::Key_Backspace:
        if (m_view && m_view->parent) {
            m_view = m_view->parent;
            m_cursor = nullptr;
            m_hover = nullptr;
            update();
            emit nodeActivated(m_view);
            m_cursor = m_view;
            refreshAccessibleText();
            event->accept();
            return;
        }
        break;
    default:
        break;
    }
    QWidget::keyPressEvent(event);
}

void DiskChart::focusInEvent(QFocusEvent *event) {
    QWidget::focusInEvent(event);
    // Tabbing into the chart with no cursor left means no visible selection,
    // and a screen reader reading the chart hears no folder at all. Land on
    // the current folder and put its name and size in the description, which
    // is read after the name. The name itself stays the control's name.
    if (!m_cursor) m_cursor = m_view;
    update();
    refreshAccessibleText();
}

void DiskChart::focusOutEvent(QFocusEvent *event) {
    QWidget::focusOutEvent(event);
    // The ring is drawn only under focus, so leaving has to repaint.
    update();
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
        // Slices accumulate from 90 degrees, so a late one starts past 360 and
        // `ang - h.start` is negative. std::fmod keeps the sign of its first
        // argument, so the wrap has to be added by hand; a negative angle then
        // compared with `a <= h.span` matches every slice.
        qreal a = std::fmod(ang - h.start, 360.0);
        if (a < 0) a += 360.0;
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
    // A click is a selection too: leaving the cursor on the clicked folder
    // means the focus ring and the announced value match what was picked.
    m_cursor = n;
    refreshAccessibleText();
    emit nodeActivated(n);
}

void DiskChart::mouseMoveEvent(QMouseEvent *event) {
    DiskNode *n = hitAt(event->pos());
    if (n != m_hover) {
        m_hover = n;
        update();
        if (n) {
            // `QToolTip` guesses markup from the first characters, so a folder
            // named `<b>Ünïcode</b>` renders bold and the tooltip stops naming
            // the directory. Same escaping as every other tooltip in the app.
            const QString tip = plainTooltip(n->name + QLatin1Char('\n')
                + humanSize(n->metric(m_allocated)) + QLatin1Char('\n')
                + n->path);
            QToolTip::showText(event->globalPosition().toPoint(), tip, this);
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
