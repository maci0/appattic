#ifndef APPATTIC_UISTYLE_H
#define APPATTIC_UISTYLE_H

#include <QAbstractItemView>
#include <QAccessible>
#include <QAction>
#include <QApplication>
#include <QFont>
#include <QFontDatabase>
#include <QFontInfo>
#include <QFontMetrics>
#include <QFrame>
#include <QLabel>
#include <QPalette>
#include <QStyle>
#include <QStyleOptionViewItem>
#include <QToolBar>
#include <QWidget>

// TMOG type roles on Linux: Selawik for UI when installed, Michroma for
// page titles, tabular figures on sizes, desktop fixed font on paths.
// No VFD digits or bloom.

// Called once from the composition root (applyAppIdentity). The font database
// is process-global; there is no second caller to keep idempotent for.
inline void aaLoadAppFonts() {
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/Michroma-Regular.ttf"));
    const QStringList wanted = {
        QStringLiteral("Selawik"),
        QStringLiteral("Segoe UI"),
        QStringLiteral("Segoe UI Variable"),
    };
    const QStringList installed = QFontDatabase::families();
    for (const QString &fam : wanted) {
        if (!installed.contains(fam, Qt::CaseInsensitive)) continue;
        QFont f(fam);
        if (QApplication::font().pointSize() > 0) f.setPointSize(QApplication::font().pointSize());
        QApplication::setFont(f);
        break;
    }
}

inline QFont aaBodyFont() {
    return QApplication::font();
}

/// Families the app names a script outside the Latin alphabet with, in the
/// order Qt should try them. Michroma carries Latin only and the desktop fixed
/// font is Latin on most distributions, so a single-family QFont has no glyph
/// to draw for a CJK, Arabic, or Cyrillic character and Qt paints the tofu box
/// instead. Each candidate is checked against the font database, so an
/// uninstalled family costs nothing.
inline QStringList aaScriptFallbackFamilies() {
    static const QStringList candidates = {
        QStringLiteral("Noto Sans CJK SC"),
        QStringLiteral("Noto Sans CJK JP"),
        QStringLiteral("Noto Sans"),
        QStringLiteral("Noto Sans Arabic"),
        QStringLiteral("Noto Sans Hebrew"),
        QStringLiteral("Noto Sans Devanagari"),
        QStringLiteral("DejaVu Sans"),
    };
    const QStringList installed = QFontDatabase::families();
    QStringList out;
    for (const QString &fam : candidates) {
        if (installed.contains(fam, Qt::CaseInsensitive)) out << fam;
    }
    return out;
}

/// Keep the face, add the script fallbacks behind it. Qt picks per character,
/// so a Latin title still draws in the display face and only the characters it
/// lacks come from the next family.
inline QFont aaWithScriptFallback(const QFont &f) {
    QFont out = f;
    QStringList fams;
    fams << f.family();
    for (const QString &fam : aaScriptFallbackFamilies()) {
        if (fam.compare(f.family(), Qt::CaseInsensitive) != 0) fams << fam;
    }
    out.setFamilies(fams);
    return out;
}

inline QFont aaSmallFont() {
    QFont f = QApplication::font();
    const int ps = f.pointSize();
    if (ps >= 12) f.setPointSize(ps - 1);
    else if (ps <= 0 && f.pixelSize() >= 16) f.setPixelSize(f.pixelSize() - 2);
    return f;
}

inline QFont aaTitleFont() {
    QFont f = QApplication::font();
    f.setWeight(QFont::DemiBold);
    return f;
}

// Page and section titles are steps above the body size, not point sizes of
// their own. 14pt and 12pt were the same shape as a 10pt desktop font and
// nothing else: on a desktop set to 16pt text the page title came out below
// the body text it labels. Pixels step at 3:2, the ratio `aaValueFont` uses.
constexpr int kPageTitleStepPt = 4;
constexpr int kSectionTitleStepPt = 2;

inline QFont aaSteppedTitleFont(int stepPt) {
    QFont f(QStringLiteral("Michroma"));
    if (!QFontInfo(f).family().contains(QLatin1String("Michroma"), Qt::CaseInsensitive)) {
        f = aaTitleFont();
    }
    // A font built from a family name alone carries no size, so the step is
    // taken from the application font every other role scales with.
    const QFont app = QApplication::font();
    if (app.pointSize() > 0) f.setPointSize(app.pointSize() + stepPt);
    else if (app.pixelSize() > 0) f.setPixelSize(app.pixelSize() + stepPt * 3 / 2);
    f.setLetterSpacing(QFont::PercentageSpacing, 102);
    return aaWithScriptFallback(f);
}

inline QFont aaPageFont() { return aaSteppedTitleFont(kPageTitleStepPt); }

inline QFont aaSectionFont() { return aaSteppedTitleFont(kSectionTitleStepPt); }

inline QFont aaLabelFont() {
    QFont f = aaSmallFont();
    f.setWeight(QFont::Medium);
    f.setLetterSpacing(QFont::AbsoluteSpacing, 1.15);
    return f;
}

inline QFont aaNumericFont() {
    QFont f = QApplication::font();
#if QT_VERSION >= QT_VERSION_CHECK(6, 7, 0)
    f.setFeature(QFont::Tag("tnum"), 1);
#endif
    return f;
}

inline QFont aaValueFont() {
    QFont f = aaNumericFont();
    const int ps = f.pointSize();
    if (ps > 0) f.setPointSize(ps + 2);
    else if (f.pixelSize() > 0) f.setPixelSize(f.pixelSize() + 3);
    f.setWeight(QFont::DemiBold);
    return f;
}

inline QFont aaMonoFont() {
    QFont f = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    const QFont body = QApplication::font();
    if (body.pointSize() > 0) f.setPointSize(body.pointSize());
    else if (body.pixelSize() > 0) f.setPixelSize(body.pixelSize());
    // Paths are the widest user-supplied text in the app, and a CJK or
    // accented path is the normal case, not the exception.
    return aaWithScriptFallback(f);
}

// Spacing scale, the one `Metrics` gives the AppKit window and the one
// DESIGN.md declares. A layout gap, margin, or padding is a step on it, not
// a number picked at the call site, so a page reads at the same density
// whichever shell draws it. `kSpaceTight` is the one step below the scale,
// for a label sitting on the value it labels.
constexpr int kSpaceTight = 2;
constexpr int kSpaceXs = 4;
constexpr int kSpaceSm = 8;
constexpr int kSpaceMd = 12;
constexpr int kSpaceLg = 16;

// Row and pane separators. The AppKit window spells this value out
// (`appHairline` in Sources/AppAttic/Theme.swift), so both shells draw the
// same line. The default Qt frame color is a different strength under every
// platform theme, which is why the rules are painted from here.
inline QColor aaHairlineColor(const QPalette &p) {
    return p.color(QPalette::Window).lightness() < 128 ? QColor(76, 76, 76) : QColor(194, 194, 194);
}

inline void aaApplyHairline(QFrame *line, const QPalette &p) {
    if (!line) return;
    QPalette lp = line->palette();
    lp.setColor(QPalette::WindowText, aaHairlineColor(p));
    lp.setColor(QPalette::Text, aaHairlineColor(p));
    line->setPalette(lp);
}

inline int aaRowPx(const QWidget *w = nullptr) {
    const QFontMetrics fm(aaBodyFont());
    const int floor = fm.height() + 8;
    if (!w) return floor;
    QStyleOptionViewItem opt;
    opt.initFrom(w);
    opt.font = aaBodyFont();
    opt.fontMetrics = fm;
    opt.features = QStyleOptionViewItem::HasDisplay;
    opt.text = QStringLiteral("Ag");
    const QSize sz = w->style()->sizeFromContents(
        QStyle::CT_ItemViewItem,
        &opt,
        QSize(100, fm.height()),
        w
    );
    return qMax(sz.height(), floor);
}

/// Let a toolbar's informational labels give up width before its controls do.
///
/// A `QToolBar` that cannot fit its items does not shrink them: it moves the
/// tail into the "»" overflow chevron, and the first to go is whatever sits
/// rightmost. On this window the rightmost items are the ones the user needs to
/// act -- Search, Select All, Rescan -- so at the window's own minimum width
/// the primary actions sat behind a chevron with no field and no button on
/// screen. A page title and a count only restate what the page already says, so
/// they are the items that may yield: `Ignored` lets them elide down to
/// `minPx` and no further, and the controls keep their natural width.
///
/// `minPx` is a floor in real pixels, not a font metric, so a longer
/// translation elides instead of pushing the controls out again.
inline void aaElidableToolbarLabel(QLabel *label, int minPx = 120) {
    if (!label) return;
    label->setMinimumWidth(minPx);
    label->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
}

/// The width a toolbar needs before it starts hiding items into the overflow
/// chevron. A toolbar with a filler spacer absorbs the difference in that
/// spacer, so this is the sum of the real controls and nothing else. Measured
/// rather than hardcoded: the fonts differ per platform and the labels carry
/// locale-formatted counts, so a fixed number here would go stale the first
/// time a translation or a font changed it.
inline int aaToolbarContentWidth(const QToolBar *bar) {
    if (!bar) return 0;
    int total = 0;
    // widgetForAction takes a non-const action even on a const toolbar, so the
    // actions are copied rather than iterated by reference.
    const QList<QAction *> actions = bar->actions();
    for (QAction *a : actions) {
        QWidget *w = bar->widgetForAction(a);
        if (!w || !w->isWidgetType()) continue;
        // A filler spacer is the toolbar's slack: it has no content to show and
        // shrinks to nothing first, so it must not count toward the width the
        // window has to promise. An elidable label (Ignored) does have a floor
        // -- the minimumWidth aaElidableToolbarLabel set on it -- and the
        // toolbar will not shrink it past that, so the floor is what counts.
        if (w->sizePolicy().horizontalPolicy() == QSizePolicy::Ignored
            && w->minimumWidth() <= 0) {
            continue;
        }
        const int floor = w->minimumWidth();
        total += floor > 0 ? floor : w->sizeHint().width();
    }
    return total;
}

inline void aaApplySourceList(QAbstractItemView *view) {
    if (!view) return;
    QPalette p = view->palette();
    const QColor window = p.color(QPalette::Window);
    p.setColor(QPalette::Base, window);
    p.setColor(QPalette::AlternateBase, window);
    view->setPalette(p);
    view->setAutoFillBackground(true);
    if (QWidget *vp = view->viewport()) {
        vp->setAutoFillBackground(true);
        vp->setPalette(p);
    }
    view->setFrameShape(QFrame::NoFrame);
}

/// Raise the palette's placeholder text to the 4.5:1 floor (WCAG 1.4.3) and
/// return the palette to set. A stock Qt `PlaceholderText` is around #808080,
/// which measures about 3.7:1 on a light window and 4.0:1 on a dark one; this
/// app uses that role for real text (hints, empty states, secondary counts),
/// not just for ghosted input text, so it cannot stay where the theme puts it.
/// The hue is nudged toward the window's own text so it still reads as the
/// quieter of the two. Returns by value: the caller decides where it lands.
inline QPalette aaPaletteWithReadablePlaceholder(const QPalette &in) {
    QPalette p = in;
    // Picked from the window it will sit on rather than from a fixed pair, so
    // the floor holds on a theme whose window is darker than Qt's own. Both
    // measure 4.5:1 or better across the whole range of window lightness they
    // are meant for: the light grey holds 4.67:1 down to a window value of 200,
    // the lighter grey holds 4.97:1 down to 60 and 8:1 or better below that.
    const bool dark = in.color(QPalette::Window).lightness() < 128;
    p.setColor(QPalette::PlaceholderText, dark ? QColor(174, 174, 174) : QColor(82, 82, 82));
    return p;
}

/// Speak a message the user did not ask for and cannot see change: a scan
/// failing, a run finishing, a folder trashed. The status bar already covers
/// routine progress; this is the one call for the messages that would
/// otherwise appear silently on a screen reader.
///
/// `QAccessible::updateAccessibility` is a no-op with no bridge running, so
/// this costs nothing in a session with no screen reader attached.
inline void aaAnnounce(QObject *obj, const QString &message) {
    if (!obj || message.isEmpty()) return;
    QAccessibleAnnouncementEvent ev(obj, message);
    // Polite: these land beside whatever the user is doing rather than cutting
    // across it.
    ev.setPoliteness(QAccessible::AnnouncementPoliteness::Polite);
    QAccessible::updateAccessibility(&ev);
}

/// The same, interrupting: for a message the user must not miss, which in this
/// app is a failed scan and nothing else. `Alert` is a static role, so it
/// reaches assistive tech even where the widget carries no name of its own.
inline void aaAlert(QObject *obj, const QString &message) {
    if (!obj || message.isEmpty()) return;
    QAccessibleEvent ev(obj, QAccessible::Alert);
    QAccessible::updateAccessibility(&ev);
    aaAnnounce(obj, message);
}

#endif
