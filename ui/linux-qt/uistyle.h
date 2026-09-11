#ifndef APPATTIC_UISTYLE_H
#define APPATTIC_UISTYLE_H

#include <QAbstractItemView>
#include <QApplication>
#include <QFont>
#include <QFontDatabase>
#include <QFontInfo>
#include <QFontMetrics>
#include <QFrame>
#include <QPalette>
#include <QStyle>
#include <QStyleOptionViewItem>
#include <QWidget>

// TMOG type roles on Linux: Selawik for UI when installed, Michroma for
// page titles, tabular figures on sizes, desktop fixed font on paths.
// No VFD digits or bloom.

inline void aaLoadAppFonts() {
    static bool once = false;
    if (once) return;
    once = true;
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

inline QFont aaPageFont() {
    QFont f(QStringLiteral("Michroma"));
    if (!QFontInfo(f).family().contains(QLatin1String("Michroma"), Qt::CaseInsensitive)) {
        f = aaTitleFont();
    }
    f.setPointSize(14);
    f.setLetterSpacing(QFont::PercentageSpacing, 102);
    return f;
}

inline QFont aaSectionFont() {
    QFont f = aaPageFont();
    f.setPointSize(12);
    return f;
}

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
    return f;
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

#endif
