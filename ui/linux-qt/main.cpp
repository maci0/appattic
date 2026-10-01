#include "corehost.h"
#include "diskchart.h"
#include "diskpage.h"
#include "diskusage.h"
#include "finding.h"
#include "findingmodel.h"
#include "scanworker.h"
#include "scriptproc.h"
#include "settings.h"
#include "smoke.h"
#include "uistyle.h"

#include <QAbstractItemView>
#include <QAction>
#include <QApplication>
#include <QAtomicInteger>
#include <QByteArray>
#include <QCheckBox>
#include <QClipboard>
#include <QCollator>
#include <QColor>
#include <QComboBox>
#include <QCoreApplication>
#include <QDateTime>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QElapsedTimer>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QFontMetrics>
#include <QFrame>
#include <QGuiApplication>
#include <QHash>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QIcon>
#include <QIODevice>
#include <QKeySequence>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QListWidgetItem>
#include <QLocale>
#include <QMainWindow>
#include <QMenu>
#include <QMenuBar>
#include <QMetaType>
#include <QMessageBox>
#include <QModelIndex>
#include <QObject>
#include <QPainter>
#include <QPalette>
#include <QPlainTextEdit>
#include <QProgressBar>
#include <QPushButton>
#include <QRect>
#include <QSaveFile>
#include <QScrollArea>
#include <QSet>
#include <QSignalBlocker>
#include <QSize>
#include <QSizePolicy>
#include <QSplitter>
#include <QStackedWidget>
#include <QStatusBar>
#include <QStyle>
#include <QStyleHints>
#include <QStyleOptionViewItem>
#include <QStyledItemDelegate>
#include <QThread>
#include <QTimer>
#include <QToolBar>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QUrl>
#include <QVariant>
#include <QVBoxLayout>
#include <QVector>
#include <QWidget>
#include <QTemporaryDir>

#include <cstdio>
#include <cstring>
#include <string>
#include <utility>

static void resetWidgetPalette(QWidget *w) {
    if (!w) return;
    w->setAttribute(Qt::WA_SetPalette, false);
    w->setPalette(QApplication::palette());
}

static QString packageChildMarkKey(const QString &parentUid, const QString &child) {
    return parentUid + QChar(0x1e) + child;
}


/// How long the destructor waits for the scan thread. A run notices the cancel
/// flag between plugins, so a normal quit returns at once; a subprocess wedged
/// past its own timeout does not, and the wait has to end for the app to.
static const int kScanThreadDrainMs = 8000;

static bool isDarkPalette(const QPalette &p) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    const Qt::ColorScheme scheme = QGuiApplication::styleHints()->colorScheme();
    if (scheme == Qt::ColorScheme::Dark) return true;
    if (scheme == Qt::ColorScheme::Light) return false;
#endif
    return p.color(QPalette::Window).lightness() < 128;
}

static QIcon themeIcon(const QString &name, const QString &fallback) {
    QIcon ic = QIcon::fromTheme(name);
    if (ic.isNull()) ic = QIcon::fromTheme(fallback);
    return ic;
}

static QString pageSearchEmpty(Page page) {
    switch (page) {
    case Page::Leftovers:
        return QStringLiteral("No leftovers match this search.");
    case Page::Stale:
        return QStringLiteral("No stale apps match this search.");
    case Page::Outdated:
        return QStringLiteral("No outdated packages match this search.");
    case Page::Packages:
        return QStringLiteral("No packages match this search.");
    default:
        return QStringLiteral("No items match this search.");
    }
}

static QString pageEmptyTitle(Page page, bool scanning, bool scanFailed) {
    if (scanning) return QStringLiteral("Scanning");
    if (scanFailed) return QStringLiteral("Scan failed");
    switch (page) {
    case Page::Leftovers:
        return QStringLiteral("No leftover data");
    case Page::Stale:
        return QStringLiteral("No stale apps");
    case Page::Outdated:
        return QStringLiteral("No outdated packages");
    case Page::Packages:
        return QStringLiteral("No unused packages");
    default:
        return QStringLiteral("Nothing to review");
    }
}

static QString pageEmptyDetail(
    Page page,
    bool scanning,
    bool scanFailed,
    const QString &search,
    int ignoredCount,
    const QString &packageFilter,
    const QString &errorText
) {
    if (scanning) {
        return QStringLiteral(
            "Looking for leftover data, stale apps, outdated packages, and unused packages."
        );
    }
    if (scanFailed) {
        return errorText.isEmpty() ? QStringLiteral("Click Rescan to try again.") : errorText;
    }
    if (!search.trimmed().isEmpty()) return pageSearchEmpty(page);
    switch (page) {
    case Page::Leftovers: {
        QString body = QStringLiteral(
            "No leftover data from uninstalled apps, and no PATH or desktop overlays hiding package-manager files."
        );
        if (ignoredCount > 0) {
            body += QLatin1Char(' ')
                + (ignoredCount == 1
                    ? QStringLiteral("1 leftover path hidden from the list.")
                    : localeCount(ignoredCount) + QStringLiteral(" leftover paths hidden from the list."));
        }
        return body;
    }
    case Page::Stale:
        return QStringLiteral("No unused installed apps in this scan.");
    case Page::Outdated:
        return QStringLiteral(
            "No outdated packages. Brew, Flatpak, Snap, apt, pacman, AUR, dnf, yum, zypper, and the App Store reported nothing, or those tools are not installed."
        );
    case Page::Packages:
        if (packageFilter == QLatin1String("globals")) {
            return QStringLiteral("No user-global npm, pnpm, bun, pipx, or uv tools.");
        }
        if (packageFilter == QLatin1String("leaves")) {
            return QStringLiteral(
                "No distro orphans. apt/pacman/dnf/yum/zypper reported nothing, or those tools are not installed."
            );
        }
        return QStringLiteral(
            "No distro orphans or language globals. Missing package managers simply have nothing to list."
        );
    default:
        return QStringLiteral("No leftover data, stale apps, or outdated packages in this scan.");
    }
}

static QString outdatedVersionLabel(const Finding &f) {
    if (f.kind.contains(QLatin1String("untrusted")) || f.status == QLatin1String("untrusted")) {
        return QStringLiteral("untrusted tap");
    }
    // Same word the size column uses when a value is missing, instead of a bare
    // dash next to real versions.
    if (f.currentVersion.isEmpty() && f.latestVersion.isEmpty()) return QStringLiteral("unknown");
    return (f.currentVersion.isEmpty() ? QStringLiteral("-") : f.currentVersion)
        + QStringLiteral(" → ")
        + (f.latestVersion.isEmpty() ? QStringLiteral("?") : f.latestVersion);
}

static QString scanSummaryMessage(int leftovers, int stale, int outdated, int packages, const QString &when) {
    return QStringLiteral("Scanned %1 · %2 leftovers, %3 stale, %4 outdated, %5 packages")
        .arg(when.isEmpty() ? QStringLiteral("now") : when)
        .arg(localeCount(leftovers))
        .arg(localeCount(stale))
        .arg(localeCount(outdated))
        .arg(localeCount(packages));
}

/* The settings path is under the account home, so the account name is in it.
   Redact before it reaches the error bar, where it is copied into bug
   reports and screenshots. `~/...` still names the file to fix. */
/* The ignore list is the user's own paths and no scan rebuilds it, so the
   settings.json.bak beside this file is the only other copy and the recovery
   path a user needs named here, not left in a runbook they have not opened.
   The restore checks that the backup loads before it puts it back and keeps
   what was there as settings.json.bad; docs/runbooks/state-recovery.md has the
   manual sequence. */
static QString settingsUnreadableMessage(const QString &path) {
    return redactHomePaths(QStringLiteral(
        "Could not read settings at %1. AppAttic will not overwrite that file until you save "
        "settings. The backup %1.bak holds the settings from before the last change."
    ).arg(path));
}

static QString settingsInvalidMessage(const QString &path, const QString &err) {
    return redactHomePaths(QStringLiteral(
        "Settings at %1 are not valid (%2). AppAttic will not overwrite that file until you save "
        "settings. The backup %1.bak holds the settings from before the last change."
    ).arg(path, err));
}

static QString settingsLegacyMessage(const QStringList &keys, const QString &path) {
    return redactHomePaths(QStringLiteral(
        "Old settings for %1 in %2 cannot be carried over, so the window opens with none. "
        "Edit that file so they read true or false (ignoredLeftovers entries must be full "
        "paths), then start the window again. Nothing is written to settings.json until then."
    ).arg(keys.join(QStringLiteral(", ")), path));
}

static QString settingsUnwritableMessage(const QString &path) {
    return redactHomePaths(QStringLiteral("Could not save settings to %1.").arg(path));
}

static QString ignoredPathLabel(const QString &path) {
    const QFileInfo fi(path);
    const QString name = fi.fileName();
    const QString parent = fi.dir().dirName();
    if (parent.isEmpty() || parent == QLatin1String(".")) {
        return name.isEmpty() ? path : name;
    }
    return parent + QLatin1Char('/') + name;
}

struct Tone {
    QColor text;
    QColor dim;
    QColor red;
    QColor amber;
    QColor green;
};

static Tone toneFrom(const QPalette &p) {
    const bool dark = isDarkPalette(p);
    Tone t;
    t.text = p.color(QPalette::WindowText);
    t.dim = dark ? QColor(174, 174, 174) : QColor(82, 82, 82);
    t.red = dark ? QColor(255, 69, 58) : QColor(192, 28, 40);
    t.amber = dark ? QColor(255, 214, 10) : QColor(158, 102, 0);
    // "keep" is text, not a decoration, so it answers to 4.5:1 (WCAG 1.4.3).
    // The green this replaces measured 4.10:1 on the light window and 3.86:1
    // on a slightly lighter one, which is below the floor; this one measures
    // 5.55:1 on the lightest window a Qt light palette paints and still
    // reads as the same green next to the amber and red above it.
    t.green = dark ? QColor(48, 209, 88) : QColor(28, 110, 48);
    return t;
}

static QColor statusColor(const Finding &f, const Tone &t, Page page) {
    if (page == Page::Packages) {
        return isGlobalKind(f) ? t.amber : t.red;
    }
    if (f.status == QLatin1String("orphaned") || f.status == QLatin1String("remove")) return t.red;
    if (f.status == QLatin1String("review") || f.status == QLatin1String("shadow")
        || f.status == QLatin1String("outdated")) {
        return t.amber;
    }
    if (f.status == QLatin1String("keep")) return t.green;
    return t.dim;
}

class SidebarDelegate : public QStyledItemDelegate {
public:
    explicit SidebarDelegate(QObject *parent = nullptr) : QStyledItemDelegate(parent) {}

    void paint(QPainter *p, const QStyleOptionViewItem &opt, const QModelIndex &idx) const override {
        QStyleOptionViewItem o = opt;
        initStyleOption(&o, idx);
        const QWidget *w = o.widget;
        QStyle *style = w ? w->style() : QApplication::style();
        const int count = idx.data(Qt::UserRole).toInt();
        int cw = 0;
        QString countText;
        if (count > 0) {
            countText = localeCount(count);
            cw = QFontMetrics(aaSmallFont()).horizontalAdvance(countText) + 12;
            o.rect.setWidth(qMax(0, o.rect.width() - cw));
        }
        style->drawControl(QStyle::CE_ItemViewItem, &o, p, w);
        if (cw <= 0) return;
        QColor dim = o.palette.color(
            o.state & QStyle::State_Selected ? QPalette::HighlightedText : QPalette::PlaceholderText
        );
        if (o.state & QStyle::State_Selected) dim.setAlpha(210);
        p->save();
        p->setPen(dim);
        p->setFont(aaSmallFont());
        // The badge belongs on the trailing edge, which is the left one once
        // the layout direction flips. `o.rect.right()` alone pins it to the
        // physical right and pushes it off the row in Arabic or Hebrew.
        const bool rtl = opt.direction == Qt::RightToLeft;
        p->drawText(
            QRect(rtl ? o.rect.left() : o.rect.right(), opt.rect.top(), cw - 8, opt.rect.height()),
            rtl ? (Qt::AlignVCenter | Qt::AlignLeft) : (Qt::AlignVCenter | Qt::AlignRight),
            countText
        );
        p->restore();
    }

    QSize sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &idx) const override {
        QStyleOptionViewItem o = opt;
        initStyleOption(&o, idx);
        const QWidget *w = o.widget;
        QStyle *style = w ? w->style() : QApplication::style();
        QSize s = style->sizeFromContents(
            QStyle::CT_ItemViewItem,
            &o,
            QStyledItemDelegate::sizeHint(opt, idx),
            w
        );
        s.setHeight(qMax(s.height(), aaRowPx(w)));
        return s;
    }
};

class TableRowDelegate : public QStyledItemDelegate {
public:
    explicit TableRowDelegate(QObject *parent = nullptr) : QStyledItemDelegate(parent) {}

    void initStyleOption(QStyleOptionViewItem *option, const QModelIndex &index) const override {
        QStyledItemDelegate::initStyleOption(option, index);
        option->showDecorationSelected = true;
        if (option->state & QStyle::State_Selected) {
            const QColor onAccent = option->palette.color(QPalette::HighlightedText);
            option->palette.setColor(QPalette::Text, onAccent);
            option->palette.setColor(QPalette::WindowText, onAccent);
            option->palette.setColor(QPalette::HighlightedText, onAccent);
            option->palette.setBrush(QPalette::Text, onAccent);
            option->palette.setBrush(QPalette::WindowText, onAccent);
            option->palette.setBrush(QPalette::HighlightedText, onAccent);
        }
        // Column 0 only: QTreeWidget flags are per item, so without this the
        // overview tables drew a check box in every column of a checkable row.
        if (index.column() == 0 && (index.flags() & Qt::ItemIsUserCheckable)) {
            option->features |= QStyleOptionViewItem::HasCheckIndicator;
            option->checkState = static_cast<Qt::CheckState>(
                index.data(Qt::CheckStateRole).toInt()
            );
        }
    }

    QSize sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &index) const override {
        QSize s = QStyledItemDelegate::sizeHint(opt, index);
        s.setHeight(cachedRowPx(opt.widget));
        return s;
    }

private:
    // `rowPx` builds font metrics and runs a style query, and Qt asks here for
    // every cell of every row: 77 ms vs 42 ms to fill a 2000 row table. Cache it
    // until the widget or the app font changes.
    int cachedRowPx(const QWidget *w) const {
        const QFont f = aaBodyFont();
        if (m_rowPxWidget != w || m_rowPxFont != f) {
            m_rowPxWidget = w;
            m_rowPxFont = f;
            m_rowPx = aaRowPx(w);
        }
        return m_rowPx;
    }
    mutable const QWidget *m_rowPxWidget = nullptr;
    mutable QFont m_rowPxFont;
    mutable int m_rowPx = 0;
};

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    explicit MainWindow() {
        // The title follows the page (fillCurrent), so it is not set here.
        resize(1180, 720);
        setMinimumSize(800, 520);

        m_scanThread = new QThread(this);
        m_worker = new ScanWorker;
        m_worker->moveToThread(m_scanThread);
        m_scanThread->start();
        connect(this, &MainWindow::requestScan, m_worker, &ScanWorker::run);
        connect(m_worker, &ScanWorker::progress, this, &MainWindow::scanProgress);
        connect(m_worker, &ScanWorker::partial, this, &MainWindow::scanPartial);
        connect(m_worker, &ScanWorker::finished, this, &MainWindow::scanFinished);

        auto *outer = new QSplitter(Qt::Horizontal, this);
        outer->setChildrenCollapsible(false);
        outer->setHandleWidth(1);

        auto *side = new QWidget;
        side->setFixedWidth(220);
        auto *sv = new QVBoxLayout(side);
        sv->setContentsMargins(0, kSpaceSm, 0, kSpaceSm);
        sv->setSpacing(0);
        m_sidebar = new QListWidget;
        m_sidebar->setItemDelegate(new SidebarDelegate(m_sidebar));
        m_sidebar->setAccessibleName(QStringLiteral("Pages"));
        m_sidebar->setSpacing(0);
        m_sidebar->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        m_sidebar->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
        m_sidebar->setIconSize(QSize(16, 16));
        m_sidebar->setUniformItemSizes(true);
        aaApplySourceList(m_sidebar);
        struct SideSpec {
            const char *name;
            const char *icon;
            const char *fallback;
        };
        const SideSpec pages[] = {
            {"Overview", "view-list-details", "office-chart-area"},
            {"Leftovers", "user-trash", "edit-delete"},
            {"Stale Apps", "appointment-soon", "clock"},
            {"Outdated", "software-update-available", "system-software-update"},
            {"Packages", "package-x-generic", "application-x-rpm"},
            {"Disk Usage", "drive-harddisk", "drive-harddisk-symbolic"},
        };
        for (const SideSpec &p : pages) {
            auto *it = new QListWidgetItem(
                themeIcon(QLatin1String(p.icon), QLatin1String(p.fallback)),
                QLatin1String(p.name)
            );
            it->setData(Qt::UserRole, 0);
            m_sidebar->addItem(it);
        }
        m_settingsNav = new QListWidget;
        m_settingsNav->setItemDelegate(new SidebarDelegate(m_settingsNav));
        m_settingsNav->setAccessibleName(QStringLiteral("More pages"));
        m_settingsNav->setSpacing(0);
        m_settingsNav->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        m_settingsNav->setIconSize(QSize(16, 16));
        m_settingsNav->setUniformItemSizes(true);
        m_settingsNav->setFocusPolicy(Qt::StrongFocus);
        aaApplySourceList(m_settingsNav);
        auto *settingsItem = new QListWidgetItem(
            themeIcon(QStringLiteral("configure"), QStringLiteral("preferences-system")),
            QStringLiteral("Settings")
        );
        settingsItem->setData(Qt::UserRole, 0);
        m_settingsNav->addItem(settingsItem);
        m_settingsNav->setFixedHeight(aaRowPx(m_settingsNav) + 8);
        sv->addWidget(m_sidebar, 1);
        sv->addWidget(m_settingsNav, 0);
        m_sidebar->setCurrentRow(0);
        m_settingsNav->clearSelection();

        auto *right = new QWidget;
        auto *rv = new QVBoxLayout(right);
        rv->setContentsMargins(0, 0, 0, 0);
        rv->setSpacing(0);

        auto *tools = new QToolBar;
        tools->setMovable(false);
        tools->setFloatable(false);
        tools->setIconSize(QSize(16, 16));
        tools->setToolButtonStyle(Qt::ToolButtonTextOnly);
        tools->setContextMenuPolicy(Qt::PreventContextMenu);
        m_pageTitle = new QLabel(QStringLiteral("Overview"));
        m_pageTitle->setFont(aaPageFont());
        m_pageTitle->setContentsMargins(kSpaceSm, kSpaceXs, kSpaceMd, kSpaceXs);
        m_count = new QLabel;
        m_count->setFont(aaSmallFont());
        m_count->setForegroundRole(QPalette::PlaceholderText);
        m_count->setContentsMargins(kSpaceSm, 0, kSpaceSm, 0);
        m_scanBar = new QProgressBar;
        m_scanBar->setTextVisible(false);
        m_scanBar->setFixedWidth(120);
        m_scanBar->setMaximumHeight(6);
        m_scanBar->setRange(0, 0);
        m_scanBar->setToolTip(QStringLiteral("Scan progress"));
        m_scanBar->hide();
        m_search = new QLineEdit;
        m_search->setPlaceholderText(QStringLiteral("Search"));
        m_search->setClearButtonEnabled(true);
        m_search->setFixedWidth(200);
        m_search->setToolTip(QStringLiteral("Filter the current list by name, path, or kind"));
        // The placeholder is a hint that vanishes as soon as the box has
        // text, so it is not a name: it is what a screen reader falls back to
        // while the box is empty, and "Search" never says what is searched.
        m_search->setAccessibleName(QStringLiteral("Search this list"));
        m_filter = new QComboBox;
        m_filter->setAccessibleName(QStringLiteral("Kind"));
        m_filter->addItem(QStringLiteral("All"), QStringLiteral("all"));
        m_filter->addItem(QStringLiteral("Leaves"), QStringLiteral("leaves"));
        m_filter->addItem(QStringLiteral("Globals"), QStringLiteral("globals"));
        m_filter->setItemData(
            0,
            QStringLiteral("Distro orphans and user-global language tools"),
            Qt::ToolTipRole
        );
        m_filter->setItemData(
            1,
            QStringLiteral("Distro packages nothing else still needs"),
            Qt::ToolTipRole
        );
        m_filter->setItemData(
            2,
            QStringLiteral("User-global npm, pnpm, bun, pipx, or uv tools"),
            Qt::ToolTipRole
        );
        m_filter->setToolTip(
            QStringLiteral("Leaves are distro orphans. Globals are user-level language tools.")
        );
        m_selectAll = new QPushButton(QStringLiteral("Select All"));
        m_selectAll->setToolTip(
            QStringLiteral("Include every visible item in cleanup, update, or remove")
        );
        m_rescan = new QPushButton(QStringLiteral("Rescan"));
        tools->addWidget(m_pageTitle);
        m_countAct = tools->addWidget(m_count);
        m_scanBarAct = tools->addWidget(m_scanBar);
        auto *toolSpacer = new QWidget;
        toolSpacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
        tools->addWidget(toolSpacer);
        m_searchAct = tools->addWidget(m_search);
        m_filterAct = tools->addWidget(m_filter);
        m_selectAllAct = tools->addWidget(m_selectAll);
        m_rescanAct = tools->addWidget(m_rescan);

        m_errorBar = new QWidget;
        auto *eh = new QHBoxLayout(m_errorBar);
        eh->setContentsMargins(kSpaceLg, kSpaceSm, kSpaceLg, kSpaceSm);
        eh->setSpacing(kSpaceSm);
        m_error = new QLabel;
        // Plain text: a failed run reports the path it failed on, and a path
        // is not markup.
        m_error->setTextFormat(Qt::PlainText);
        m_error->setWordWrap(true);
        auto *errDismiss = new QPushButton(QStringLiteral("Dismiss"));
        eh->addWidget(m_error, 1);
        eh->addWidget(errDismiss, 0, Qt::AlignTop);
        m_errorBar->hide();
        connect(errDismiss, &QPushButton::clicked, this, [this] {
            m_errorBar->hide();
            m_error->clear();
        });

        m_stack = new QStackedWidget;

        auto *overview = buildOverview();
        m_stack->addWidget(overview);

        auto *listPage = new QWidget;
        auto *listSplit = new QSplitter(Qt::Horizontal, listPage);
        listSplit->setChildrenCollapsible(false);
        listSplit->setHandleWidth(1);
        auto *listLay = new QHBoxLayout(listPage);
        listLay->setContentsMargins(0, 0, 0, 0);
        listLay->addWidget(listSplit);

        auto *listPane = new QWidget;
        auto *lpv = new QVBoxLayout(listPane);
        lpv->setContentsMargins(0, 0, 0, 0);
        lpv->setSpacing(0);
        m_table = new QTreeView;
        m_model = new FindingModel(this);
        m_table->setModel(m_model);
        m_table->setRootIsDecorated(false);
        m_table->setUniformRowHeights(true);
        m_table->setItemsExpandable(true);
        m_table->setIndentation(0);
        m_table->setAlternatingRowColors(false);
        m_table->setSelectionMode(QAbstractItemView::SingleSelection);
        m_table->setSelectionBehavior(QAbstractItemView::SelectRows);
        m_table->setAllColumnsShowFocus(true);
        m_table->setTextElideMode(Qt::ElideRight);
        m_table->header()->setStretchLastSection(false);
        m_table->header()->setHighlightSections(false);
        m_table->header()->setDefaultAlignment(Qt::AlignLeading | Qt::AlignVCenter);
        m_table->setFrameShape(QFrame::NoFrame);
        m_table->setItemDelegate(new TableRowDelegate(m_table));
        m_emptyPane = new QWidget;
        auto *ev = new QVBoxLayout(m_emptyPane);
        ev->setContentsMargins(kSpaceLg, kSpaceLg, kSpaceLg, kSpaceLg);
        ev->setSpacing(kSpaceSm);
        ev->addStretch();
        auto *emptyInner = new QWidget;
        auto *eiv = new QVBoxLayout(emptyInner);
        eiv->setContentsMargins(0, 0, 0, 0);
        eiv->setSpacing(kSpaceSm);
        eiv->setAlignment(Qt::AlignHCenter);
        m_emptyTitle = new QLabel;
        m_emptyTitle->setFont(aaTitleFont());
        m_emptyTitle->setAlignment(Qt::AlignCenter);
        m_emptyTitle->setWordWrap(true);
        m_emptyDetail = new QLabel;
        m_emptyDetail->setAlignment(Qt::AlignCenter);
        m_emptyDetail->setWordWrap(true);
        m_emptyDetail->setForegroundRole(QPalette::PlaceholderText);
        m_emptyDetail->setMaximumWidth(420);
        m_emptyDetail->setMinimumWidth(220);
        m_clearSearch = new QPushButton(QStringLiteral("Clear search"));
        m_clearSearch->hide();
        // "Rescan" is the name the toolbar button and the error copy use for
        // this action. A second word for the same button reads as a different
        // one.
        m_emptyRetry = new QPushButton(QStringLiteral("Rescan"));
        m_emptyRetry->hide();
        eiv->addWidget(m_emptyTitle);
        eiv->addWidget(m_emptyDetail, 0, Qt::AlignHCenter);
        eiv->addWidget(m_clearSearch, 0, Qt::AlignHCenter);
        eiv->addWidget(m_emptyRetry, 0, Qt::AlignHCenter);
        ev->addWidget(emptyInner, 0, Qt::AlignHCenter);
        ev->addStretch();
        m_emptyPane->hide();
        lpv->addWidget(m_table, 1);
        lpv->addWidget(m_emptyPane, 1);

        m_inspectorScroll = new QScrollArea;
        m_inspectorScroll->setWidgetResizable(true);
        m_inspectorScroll->setFrameShape(QFrame::NoFrame);
        m_inspectorScroll->setMinimumWidth(280);
        m_inspectorHost = new QWidget;
        m_inspectorLay = new QVBoxLayout(m_inspectorHost);
        m_inspectorLay->setContentsMargins(kSpaceLg, kSpaceLg, kSpaceLg, kSpaceLg);
        m_inspectorLay->setSpacing(kSpaceSm);
        m_inspectorScroll->setWidget(m_inspectorHost);

        listSplit->addWidget(listPane);
        listSplit->addWidget(m_inspectorScroll);
        listSplit->setStretchFactor(0, 1);
        listSplit->setStretchFactor(1, 0);
        listSplit->setSizes({760, 320});
        m_stack->addWidget(listPage);

        auto *settingsPage = buildSettings();
        m_stack->addWidget(settingsPage);
        m_diskPage = new DiskPage;
        m_stack->addWidget(m_diskPage);
        connect(m_diskPage, &DiskPage::statusMessage, this, [this](const QString &msg) {
            statusBar()->showMessage(msg);
        });

        auto *actionBar = new QToolBar;
        actionBar->setMovable(false);
        actionBar->setFloatable(false);
        actionBar->setIconSize(QSize(16, 16));
        actionBar->setToolButtonStyle(Qt::ToolButtonTextOnly);
        actionBar->setContextMenuPolicy(Qt::PreventContextMenu);
        m_actionBar = actionBar;
        m_actionCount = new QLabel;
        m_actionCount->setFont(aaSmallFont());
        m_actionCount->setContentsMargins(kSpaceSm, 0, kSpaceSm, 0);
        m_actionBytes = new QLabel;
        m_actionBytes->setFont(aaSmallFont());
        m_actionBytes->setForegroundRole(QPalette::PlaceholderText);
        m_clearSel = new QPushButton(QStringLiteral("Clear"));
        m_clearSel->setToolTip(QStringLiteral("Clear the current selection"));
        m_preview = new QPushButton(QStringLiteral("Preview Script"));
        m_markManualBtn = new QPushButton(QStringLiteral("Mark Manual"));
        m_markManualBtn->setToolTip(QStringLiteral("Mark selected distro packages as manually installed"));
        m_updateBtn = new QPushButton(QStringLiteral("Update"));
        m_deleteBtn = new QPushButton(QStringLiteral("Delete"));
        actionBar->addWidget(m_actionCount);
        actionBar->addWidget(m_actionBytes);
        auto *actionSpacer = new QWidget;
        actionSpacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
        actionBar->addWidget(actionSpacer);
        actionBar->addWidget(m_clearSel);
        actionBar->addWidget(m_preview);
        actionBar->addWidget(m_markManualBtn);
        actionBar->addWidget(m_updateBtn);
        actionBar->addWidget(m_deleteBtn);
        m_actionBar->hide();

        rv->addWidget(tools);
        rv->addWidget(m_errorBar);
        rv->addWidget(m_stack, 1);
        rv->addWidget(m_actionBar);

        outer->addWidget(side);
        outer->addWidget(right);
        outer->setStretchFactor(0, 0);
        outer->setStretchFactor(1, 1);
        outer->setSizes({220, 960});
        setCentralWidget(outer);

        auto *scanMenu = menuBar()->addMenu(QStringLiteral("Scan"));
        auto *rescanAct = scanMenu->addAction(QStringLiteral("Rescan"));
        rescanAct->setShortcut(QKeySequence::Refresh);
        connect(rescanAct, &QAction::triggered, this, &MainWindow::rescan);
        scanMenu->addSeparator();
        connect(scanMenu->addAction(QStringLiteral("Scan Home")), &QAction::triggered, this, [this] {
            selectPage(Page::DiskUsage);
            m_diskPage->scanHome();
        });
        connect(scanMenu->addAction(QStringLiteral("Scan Folder")), &QAction::triggered, this, [this] {
            selectPage(Page::DiskUsage);
            m_diskPage->scanFolder();
        });
        connect(scanMenu->addAction(QStringLiteral("Scan File System")), &QAction::triggered, this, [this] {
            selectPage(Page::DiskUsage);
            m_diskPage->scanFilesystem();
        });
        connect(scanMenu->addAction(QStringLiteral("Scan Remote")), &QAction::triggered, this, [this] {
            selectPage(Page::DiskUsage);
            m_diskPage->scanRemote();
        });
        auto *helpMenu = menuBar()->addMenu(QStringLiteral("Help"));
        auto *aboutAct = helpMenu->addAction(QStringLiteral("About AppAttic"));
        connect(aboutAct, &QAction::triggered, this, [this] {
            QMessageBox::about(
                this,
                QStringLiteral("AppAttic"),
                QStringLiteral("AppAttic " APPATTIC_VERSION "\nLeftovers, stale apps, outdated packages, disk usage.")
            );
        });

        connect(m_sidebar, &QListWidget::currentRowChanged, this, [this](int row) {
            if (row < 0) return;
            m_settingsNav->clearSelection();
            showPage();
        });
        connect(m_settingsNav, &QListWidget::itemClicked, this, [this](QListWidgetItem *) {
            m_sidebar->clearSelection();
            m_settingsNav->setCurrentRow(0);
            m_settingsNav->setFocus(Qt::MouseFocusReason);
            showPage();
        });
        connect(m_rescan, &QPushButton::clicked, this, &MainWindow::rescan);
        connect(m_search, &QLineEdit::textChanged, this, [this] {
            // Coalesce fast typing: one filter pass per pause, not per key.
            if (!m_searchDebounce) {
                m_searchDebounce = new QTimer(this);
                m_searchDebounce->setSingleShot(true);
                m_searchDebounce->setInterval(120);
                connect(m_searchDebounce, &QTimer::timeout, this, [this] { fillCurrent(); });
            }
            m_searchDebounce->start();
        });
        connect(m_filter, &QComboBox::currentIndexChanged, this, [this] { fillCurrent(); });
        connect(m_clearSearch, &QPushButton::clicked, this, [this] { m_search->clear(); });
        connect(m_emptyRetry, &QPushButton::clicked, this, &MainWindow::rescan);
        connect(m_selectAll, &QPushButton::clicked, this, &MainWindow::toggleSelectAll);
        connect(m_table->selectionModel(), &QItemSelectionModel::currentChanged, this,
                [this](const QModelIndex &cur, const QModelIndex &) {
                    m_selectedUid = cur.isValid() ? m_model->data(cur, Qt::UserRole).toString() : QString();
                    m_selectedChild =
                        cur.isValid() ? m_model->data(cur, Qt::UserRole + 1).toString() : QString();
                    rebuildInspector();
                });
        connect(m_table, &QTreeView::clicked, this, [this](const QModelIndex &idx) {
            if (!idx.isValid() || idx.column() != 0) return;
            if (m_scanning) return;
            if (currentPage() == Page::Leftovers) return;
            const QString uid = m_model->data(idx, Qt::UserRole).toString();
            if (uid.isEmpty()) return;
            const Finding *f = findingByUid(uid);
            if (!f) return;
            const QString child = m_model->data(idx, Qt::UserRole + 1).toString();
            if (!child.isEmpty()) {
                toggleRowMark(*f, child, !m_marked.contains(packageChildMarkKey(uid, child)));
                rebuildInspector();
                return;
            }
            if (m_markedManual.contains(uid)) {
                m_markedManual.remove(uid);
            } else if (m_marked.contains(uid) && !canMarkCleanup(*f, currentPage())) {
                m_marked.remove(uid);
            } else if (canMarkCleanup(*f, currentPage())) {
                if (m_marked.contains(uid)) m_marked.remove(uid);
                else {
                    m_marked.insert(uid);
                    m_markedManual.remove(uid);
                }
            } else {
                return;
            }
            m_model->refreshUid(uid);
            refreshMarkChrome();
            rebuildInspector();
        });
        connect(m_clearSel, &QPushButton::clicked, this, [this] {
            m_marked.clear();
            m_markedManual.clear();
            fillCurrent();
            rebuildInspector();
            refreshActionBar();
        });
        connect(m_preview, &QPushButton::clicked, this, &MainWindow::previewScript);
        connect(m_deleteBtn, &QPushButton::clicked, this, &MainWindow::confirmDelete);
        connect(m_updateBtn, &QPushButton::clicked, this, &MainWindow::confirmUpdate);
        connect(m_markManualBtn, &QPushButton::clicked, this, &MainWindow::confirmMarkManual);

        loadSettings();
        refreshRestoreButton();
        applySystemAppearance();
        applyInitialPage();
        fillCurrent();
        if (!m_settingsError) rescan();
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, [this](Qt::ColorScheme) {
            applySystemAppearance();
            fillCurrent();
        });
#endif
    }

    ~MainWindow() override {
        // A script still running is killed and its temp file removed by
        // ~ScriptProcess, before this window's own teardown.
        delete m_script;
        m_script = nullptr;
        if (m_worker) {
            disconnect(m_worker, nullptr, this, nullptr);
            disconnect(this, nullptr, m_worker, nullptr);
            m_worker->requestCancel();
        }
        m_scanThread->quit();
        const bool stopped = m_scanThread->wait(kScanThreadDrainMs);
        clearCoreWasmCancel();
        /* The PATH rewrite and the engine registry are process-global, and a
           run that never stopped is still reading and writing them. Tearing
           them down beside a live run is the race the host's own drain guard
           cannot see, so they wait until the thread is gone.

           The thread is never killed: a run spends its time inside the host
           under g_life_lock or g_mod_lock, and terminate() would strand that
           mutex for the next thread that takes it, wedging
           appattic_wasm_shutdown forever. It is detached instead, so ~QObject
           cannot delete a running QThread either (Qt aborts on that), and the
           process exit reclaims it together with the engine. */
        if (!stopped) {
            std::fprintf(stderr, "scan thread still running at dispose, keeping the engine\n");
            m_scanThread->setParent(nullptr);
            return;
        }
        /* Inverse of requestCancel above: leave the process-global cancel in
           the state dispose found it, and drop the scan's PATH rewrite. */
        restoreCoreWasmPath();
        delete m_worker;
        m_worker = nullptr;
        /* Inverse of the host's engine/module registry: the scans are gone, so
           the compiled modules they built do not outlive this window. */
        shutdownCoreWasm();
    }

signals:
    void requestScan(const QString &core, const QStringList &pluginSpecs, int token);

private slots:
    void showPage() {
        fillCurrent();
    }

    void rescan() {
        if (m_scanning) return;
        const QString out = coreOutDir();
        const QString core = out + QStringLiteral("/appattic_core.wasm");
        if (!QFileInfo::exists(core)) {
            m_findings.clear();
            m_scanOk = false;
            m_hasScanned = true;
            m_scanAt.clear();
            showError(QStringLiteral(
                "Scan engine is missing: no appattic_core.wasm in %1. Rebuild the app, "
                "or set APPATTIC_CORE_OUT to the directory that holds it.").arg(redactHomePaths(out)));
            fillCurrent();
            return;
        }
        m_scanning = true;
        m_scanPhase = QStringLiteral("Starting scan…");
        m_scanIndex = 0;
        m_scanTotal = 0;
        m_rescan->setEnabled(false);
        m_selectAll->setEnabled(false);
        if (m_scanBar) {
            m_scanBar->setRange(0, 0);
            m_scanBar->show();
        }
        applyScanProgressUi();
        fillCurrent();
        const int token = ++m_scanGen;
        if (m_worker) m_worker->setWanted(token);
        emit requestScan(core, taggedPluginSpecs(out), token);
    }

    void scanProgress(const QString &pluginId, int index, int total) {
        m_scanIndex = index;
        m_scanTotal = total;
        m_scanPhase = pluginScanLabel(pluginId);
        if (m_scanBar) {
            if (total > 0) {
                m_scanBar->setRange(0, total);
                m_scanBar->setValue(index);
            } else {
                m_scanBar->setRange(0, 0);
            }
            m_scanBar->show();
        }
        applyScanProgressUi();
    }

    /// Rows from the plugins that have reported so far: draw them now instead
    /// of waiting for the slowest plugin. The final list replaces this one.
    void scanPartial(const QVector<Finding> &findings) {
        if (!m_scanning) return;
#ifndef NDEBUG
        m_partialSeen += 1;
        if (m_partialRowsFirst < 0) m_partialRowsFirst = findings.size();
        for (const Finding &f : findings) m_partialUids.insert(f.uid());
#endif
        m_findings = findings;
        fillCurrent();
    }

    void scanFinished(const QVector<Finding> &findings, const QString &err, int rc,
                      const QStringList &notes) {
        m_scanning = false;
        m_scanPhase.clear();
        m_scanIndex = 0;
        m_scanTotal = 0;
        if (m_scanBar) m_scanBar->hide();
        m_hasScanned = true;
        m_rescan->setEnabled(true);
        m_findings = findings;
        pruneStaleMarks();
        m_scanOk = (rc == 0);
        m_scanAt = localeDateTimeLabel(QDateTime::currentDateTime());
        if (rc != 0) {
            /* Core stderr carries absolute paths, so the account name in the
               home prefix reaches the error bar without this. */
            showError(err.isEmpty() ? QStringLiteral("Scan failed. Click Rescan to try again.")
                                    : redactHomePaths(err.trimmed()));
        } else if (!m_settingsError) {
            m_errorBar->hide();
            m_error->clear();
            const QString summary = scanSummaryMessage(
                countPage(Page::Leftovers),
                countPage(Page::Stale),
                countPage(Page::Outdated),
                countPage(Page::Packages),
                m_scanAt
            );
            /* One line that carries the counts and, when any plugin came back
               short, the reason. The screen reader hears the same text, so an
               incomplete run is announced rather than only drawn. */
            const QString noteClause = scanNoteClause(notes);
            const QString line = noteClause.isEmpty()
                ? summary
                : summary + QLatin1String(" · ") + noteClause;
            statusBar()->showMessage(line);
            // The scan runs for a while with nothing on screen changing, and it
            // ends with a count the user has to notice. A screen reader hears
            // none of that from the list repaint.
            aaAnnounce(m_stack, line);
        } else {
            statusBar()->showMessage(
                QStringLiteral("%1 plugin findings").arg(localeCount(m_findings.size()))
            );
        }
        fillCurrent();
    }

    void toggleSelectAll() {
        if (m_scanning) return;
        const Page page = currentPage();
        const QVector<Finding> rows = visibleRows(page);
        QStringList ids;
        for (const Finding &f : rows) {
            if (canMarkCleanup(f, page)) ids << f.uid();
        }
        if (ids.isEmpty()) return;
        bool allOn = true;
        for (const QString &id : ids) {
            if (!m_marked.contains(id)) {
                allOn = false;
                break;
            }
        }
        if (allOn) {
            for (const QString &id : ids) m_marked.remove(id);
        } else {
            for (const QString &id : ids) {
                m_marked.insert(id);
                m_markedManual.remove(id);
            }
        }
        fillTable(page);
        rebuildInspector();
        refreshActionBar();
    }

    void previewScript() {
        showScriptSheet(ScriptKind::Preview, previewAllScript(), QString(), QString());
    }

    void confirmDelete() {
        if (m_scanning) return;
        const QString script = cleanupScript();
        if (!scriptHasCommands(script)) return;
        if (m_confirmDelete) {
            showScriptSheet(
                ScriptKind::Delete,
                script,
                QStringLiteral("Delete %1 selected items? This runs the uninstall script now.")
                    .arg(localeCount(cleanupMarkCount())),
                QStringLiteral("Delete")
            );
            return;
        }
        runScript(
            script,
            QStringLiteral("Removing selected items…"),
            removedMessage(cleanupMarkCount(), QStringLiteral("item"))
        );
    }

    void confirmUpdate() {
        if (m_scanning) return;
        const QString script = updateScript();
        if (!scriptHasCommands(script)) return;
        if (m_confirmDelete) {
            showScriptSheet(
                ScriptKind::Update,
                script,
                QStringLiteral("Update %1 selected packages?").arg(localeCount(updateMarkCount())),
                QStringLiteral("Update")
            );
            return;
        }
        runScript(
            script,
            QStringLiteral("Updating selected packages…"),
            updatedMessage(updateMarkCount())
        );
    }

    void confirmMarkManual() {
        if (m_scanning) return;
        const QString script = markManualScript();
        if (!scriptHasCommands(script)) return;
        if (m_confirmDelete) {
            showScriptSheet(
                ScriptKind::MarkManual,
                script,
                QStringLiteral("Mark %1 packages as manually installed?")
                    .arg(localeCount(m_markedManual.size())),
                QStringLiteral("Mark Manual")
            );
            return;
        }
        runScript(
            script,
            QStringLiteral("Marking packages as manually installed…"),
            markedMessage(m_markedManual.size())
        );
    }

    /// "Removed 3 items. Scanning again…", with the one-item form spelled
    /// out. The count is taken before the run clears the selection.
    static QString removedMessage(int n, const QString &noun) {
        if (n == 1) return QStringLiteral("Removed 1 %1. Scanning again…").arg(noun);
        return QStringLiteral("Removed %1 %2. Scanning again…").arg(localeCount(n), noun);
    }

    static QString updatedMessage(int n) {
        if (n == 1) return QStringLiteral("Updated 1 package. Scanning again…");
        return QStringLiteral("Updated %1 packages. Scanning again…").arg(localeCount(n));
    }

    static QString markedMessage(int n) {
        if (n == 1) return QStringLiteral("Marked 1 package as manually installed. Scanning again…");
        return QStringLiteral("Marked %1 packages as manually installed. Scanning again…")
            .arg(localeCount(n));
    }

private:
    enum class ScriptKind { Preview, Delete, Update, MarkManual };

    void showScriptSheet(
        ScriptKind kind,
        const QString &script,
        const QString &question,
        const QString &runLabel
    ) {
        auto *dlg = new QDialog(this);
        dlg->setWindowModality(Qt::WindowModal);
        dlg->setWindowTitle(
            kind == ScriptKind::Preview ? QStringLiteral("Review Script") : QStringLiteral("Confirm")
        );
        dlg->resize(560, 420);
        auto *v = new QVBoxLayout(dlg);
        auto *title = new QLabel(
            question.isEmpty() ? QStringLiteral("Review every line before running.") : question
        );
        title->setWordWrap(true);
        auto *hint = new QLabel(QStringLiteral("Review every line before running."));
        hint->setFont(aaSmallFont());
        hint->setForegroundRole(QPalette::PlaceholderText);
        hint->setVisible(!question.isEmpty());
        auto *edit = new QPlainTextEdit;
        edit->setFont(aaMonoFont());
        edit->setReadOnly(true);
        edit->setPlainText(script);
        // The script is the whole substance of this dialog, and a bare
        // QPlainTextEdit reads as an unnamed "text edit" to a screen reader.
        // Name it for what it holds, and say it is the thing to review.
        edit->setAccessibleName(QStringLiteral("Script to review"));
        edit->setAccessibleDescription(
            QStringLiteral("The commands that will run, one per line. This is the text to review before running.")
        );
        auto *box = new QDialogButtonBox;
        auto *copy = box->addButton(QStringLiteral("Copy"), QDialogButtonBox::ActionRole);
        connect(copy, &QPushButton::clicked, this, [script, copy] {
            if (QClipboard *cb = QGuiApplication::clipboard()) {
                cb->setText(script);
                copy->setText(QStringLiteral("Copied"));
                copy->setEnabled(false);
                // The button relabels itself and disables for a moment, and a
                // screen reader reads the label on focus rather than watching
                // it change, so the result of the copy is announced instead.
                aaAnnounce(copy, QStringLiteral("Script copied to the clipboard."));
                QTimer::singleShot(1500, copy, [copy] {
                    copy->setText(QStringLiteral("Copy"));
                    copy->setEnabled(true);
                });
            }
        });
        if (runLabel.isEmpty()) {
            box->addButton(QDialogButtonBox::Close);
            connect(box, &QDialogButtonBox::rejected, dlg, &QDialog::reject);
        } else {
            box->addButton(QStringLiteral("Cancel"), QDialogButtonBox::RejectRole);
            box->addButton(runLabel, QDialogButtonBox::AcceptRole);
            connect(box, &QDialogButtonBox::rejected, dlg, &QDialog::reject);
            connect(box, &QDialogButtonBox::accepted, dlg, &QDialog::accept);
        }
        v->addWidget(title);
        if (!question.isEmpty()) v->addWidget(hint);
        v->addWidget(edit, 1);
        v->addWidget(box);
        const int rc = dlg->exec();
        dlg->deleteLater();
        if (rc == QDialog::Accepted && !runLabel.isEmpty()) {
            QString progress = QStringLiteral("Running selected actions…");
            QString done;
            if (kind == ScriptKind::Delete) {
                progress = QStringLiteral("Removing selected items…");
                done = removedMessage(cleanupMarkCount(), QStringLiteral("item"));
            } else if (kind == ScriptKind::Update) {
                progress = QStringLiteral("Updating selected packages…");
                done = updatedMessage(updateMarkCount());
            } else if (kind == ScriptKind::MarkManual) {
                progress = QStringLiteral("Marking packages as manually installed…");
                done = markedMessage(m_markedManual.size());
            }
            runScript(script, progress, done);
        }
    }
    Page currentPage() const {
        if (m_settingsNav && !m_settingsNav->selectedItems().isEmpty()) return Page::Settings;
        const int row = m_sidebar->currentRow();
        if (row < 0) return Page::Overview;
        return static_cast<Page>(row);
    }

    void selectPage(Page page) {
        if (page == Page::Settings) {
            // clearSelection() leaves the old row as the *current* row, and the
            // sidebar paints that as a second highlight next to Settings.
            m_sidebar->setCurrentRow(-1);
            m_sidebar->clearSelection();
            if (m_settingsNav) m_settingsNav->setCurrentRow(0);
        } else {
            if (m_settingsNav) m_settingsNav->clearSelection();
            m_sidebar->setCurrentRow(int(page));
        }
        showPage();
    }

    static QString pageTitle(Page page) {
        switch (page) {
        case Page::Overview: return QStringLiteral("Overview");
        case Page::Leftovers: return QStringLiteral("Leftovers");
        case Page::Stale: return QStringLiteral("Stale Apps");
        case Page::Outdated: return QStringLiteral("Outdated");
        case Page::Packages: return QStringLiteral("Packages");
        case Page::DiskUsage: return QStringLiteral("Disk Usage");
        case Page::Settings: return QStringLiteral("Settings");
        }
        return QStringLiteral("AppAttic");
    }

    void applyInitialPage() {
        selectPage(initialPage());
    }

    /// Page name to sidebar page. False for anything not in the table.
    static bool initialPageFromName(const QString &name, Page *out) {
        static const QHash<QString, Page> pages = {
            {QStringLiteral("overview"), Page::Overview},
            {QStringLiteral("leftovers"), Page::Leftovers},
            {QStringLiteral("stale"), Page::Stale},
            {QStringLiteral("outdated"), Page::Outdated},
            {QStringLiteral("packages"), Page::Packages},
            {QStringLiteral("disk"), Page::DiskUsage},
            {QStringLiteral("settings"), Page::Settings},
        };
        const auto it = pages.constFind(name);
        if (it == pages.constEnd()) return false;
        *out = it.value();
        return true;
    }

    /// Sidebar to open, from APPATTIC_PAGE. An empty or unset value opens the
    /// overview. An unknown name is a misconfiguration, not a silent fallback,
    /// so it is reported on stderr and the overview opens.
    static Page initialPage() {
        const QString v = QString::fromUtf8(qgetenv("APPATTIC_PAGE")).trimmed();
        if (v.isEmpty()) return Page::Overview;
        Page page = Page::Overview;
        if (initialPageFromName(v, &page)) return page;
        std::fprintf(
            stderr,
            "appattic: APPATTIC_PAGE=\"%s\" is not a page name; opening overview. "
            "Valid values: overview, leftovers, stale, outdated, packages, disk, settings.\n",
            v.toUtf8().constData()
        );
        return Page::Overview;
    }

    void showError(const QString &msg) {
        const Tone t = toneFrom(palette());
        QPalette p = m_error->palette();
        p.setColor(QPalette::WindowText, t.red);
        m_error->setPalette(p);
        m_error->setText(msg);
        m_errorBar->show();
        statusBar()->showMessage(msg);
        // A failed scan is the one message the user must not miss, and the bar
        // is a plain widget that appears where it was not: nothing about it
        // reaches a screen reader on its own. Announce it, and name the label
        // so focus landing there later reads as the error it is.
        m_error->setAccessibleName(QStringLiteral("Error"));
        m_errorBar->setAccessibleDescription(msg);
        aaAlert(m_error, msg);
    }

    QWidget *buildOverview() {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(0, 0, 0, 0);
        v->setSpacing(0);
        auto *stats = new QWidget;
        auto *sg = new QHBoxLayout(stats);
        sg->setContentsMargins(kSpaceSm, kSpaceSm, kSpaceSm, kSpaceXs);
        sg->setSpacing(0);
        m_statLeftovers = addInstrument(sg, QStringLiteral("Leftovers"));
        m_statLeftoverData = addInstrument(sg, QStringLiteral("Leftover data"));
        m_statStale = addInstrument(sg, QStringLiteral("Stale"));
        m_statOutdated = addInstrument(sg, QStringLiteral("Outdated"));
        m_statPackages = addInstrument(sg, QStringLiteral("Packages"));
        m_statInstalled = addInstrument(sg, QStringLiteral("Installed"));
        m_statScan = addInstrument(sg, QStringLiteral("Last scan"));
        sg->addStretch();
        v->addWidget(stats);

        auto *line = new QFrame;
        line->setFrameShape(QFrame::HLine);
        line->setFrameShadow(QFrame::Plain);
        aaApplyHairline(line, palette());
        v->addWidget(line);

        auto *cols = new QSplitter(Qt::Horizontal);
        cols->setChildrenCollapsible(false);
        cols->setHandleWidth(1);
        m_ovLeftovers = makeOverviewTree(QStringLiteral("Size"));
        m_ovStale = makeOverviewTree(QStringLiteral("Size"));
        m_ovOutdated = makeOverviewTree(QStringLiteral("Version"));
        cols->addWidget(wrapOverviewCol(QStringLiteral("Largest leftovers"), m_ovLeftovers, &m_ovLeftEmpty));
        cols->addWidget(wrapOverviewCol(QStringLiteral("Largest stale apps"), m_ovStale, &m_ovStaleEmpty));
        cols->addWidget(wrapOverviewCol(QStringLiteral("Outdated packages"), m_ovOutdated, &m_ovOutEmpty));
        cols->setStretchFactor(0, 1);
        cols->setStretchFactor(1, 1);
        cols->setStretchFactor(2, 1);
        cols->setSizes({380, 380, 380});
        v->addWidget(cols, 1);
        /* Every row here opens the page it came from, from a pointer and from
           the keyboard. `itemClicked` alone left a keyboard or screen-reader
           user with no way in: the tree takes focus, the arrows move the
           current row, and Enter did nothing, while the hint under the column
           title and the table's accessible description both promise Enter
           works. `itemActivated` is the keyboard half (Enter, and Return on the
           platforms that send it instead), so it is wired beside the click. */
        auto openOverviewRow = [this](QTreeWidgetItem *it, Page page) {
            if (!it) return;
            m_selectedUid = it->data(0, Qt::UserRole).toString();
            selectPage(page);
        };
        connect(m_ovLeftovers, &QTreeWidget::itemClicked, this, [openOverviewRow](QTreeWidgetItem *it, int) {
            openOverviewRow(it, Page::Leftovers);
        });
        connect(m_ovLeftovers, &QTreeWidget::itemActivated, this, [openOverviewRow](QTreeWidgetItem *it, int) {
            openOverviewRow(it, Page::Leftovers);
        });
        connect(m_ovStale, &QTreeWidget::itemClicked, this, [openOverviewRow](QTreeWidgetItem *it, int) {
            openOverviewRow(it, Page::Stale);
        });
        connect(m_ovStale, &QTreeWidget::itemActivated, this, [openOverviewRow](QTreeWidgetItem *it, int) {
            openOverviewRow(it, Page::Stale);
        });
        connect(m_ovOutdated, &QTreeWidget::itemClicked, this, [openOverviewRow](QTreeWidgetItem *it, int) {
            openOverviewRow(it, Page::Outdated);
        });
        connect(m_ovOutdated, &QTreeWidget::itemActivated, this, [openOverviewRow](QTreeWidgetItem *it, int) {
            openOverviewRow(it, Page::Outdated);
        });
        return w;
    }

    QLabel *addInstrument(QHBoxLayout *row, const QString &label) {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(kSpaceLg, kSpaceSm, kSpaceLg, kSpaceSm);
        v->setSpacing(kSpaceTight);
        auto *l = new QLabel(label.toUpper());
        l->setFont(aaLabelFont());
        l->setForegroundRole(QPalette::PlaceholderText);
        l->setWordWrap(true);
        auto *val = new QLabel(QStringLiteral("unknown"));
        val->setFont(aaValueFont());
        // Wrapping is what lets the row shrink: a plain label's minimum width
        // is its whole text, so seven instruments overflowed the window at
        // small widths and the last ones (Last scan) were cut off with no way
        // to read them. A wrapped label wraps instead.
        val->setWordWrap(true);
        v->addWidget(l);
        v->addWidget(val);
        row->addWidget(w, 0, Qt::AlignTop);
        return val;
    }

    QTreeWidget *makeOverviewTree(const QString &trailing) {
        auto *t = new QTreeWidget;
        // Every row here opens the page it came from. The rows carry their own
        // tooltips (name, what, path), so the affordance is the pointer and
        // the hint under the column title, not a widget tooltip.
        t->setCursor(Qt::PointingHandCursor);
        t->setRootIsDecorated(false);
        t->setUniformRowHeights(true);
        t->setIndentation(0);
        t->setHeaderLabels({QStringLiteral("Name"), QStringLiteral("What"), trailing});
        t->header()->setStretchLastSection(false);
        // Only the name takes the slack: "What" and the trailing column are
        // short labels, and stretching them elided names that had room.
        t->header()->setSectionResizeMode(0, QHeaderView::Stretch);
        t->header()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
        t->header()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
        t->setFrameShape(QFrame::NoFrame);
        t->setTextElideMode(Qt::ElideRight);
        t->header()->setHighlightSections(false);
        t->setItemDelegate(new TableRowDelegate(t));
        t->setColumnHidden(1, false);
        return t;
    }

    QWidget *wrapOverviewCol(const QString &title, QTreeWidget *tree, QLabel **emptyOut) {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(0, 0, 0, 0);
        v->setSpacing(0);
        auto *h = new QLabel(title);
        h->setFont(aaSectionFont());
        h->setContentsMargins(kSpaceLg, kSpaceSm, kSpaceLg, kSpaceXs);
        // The heading is a QLabel, which a screen reader reads as loose text and
        // never ties to the table under it. Naming the table with it means
        // reaching the table says which of the three panels it is.
        tree->setAccessibleName(title);
        tree->setAccessibleDescription(
            QStringLiteral("Select a row, then press Enter, to open it on its own page.")
        );
        auto *rule = new QFrame;
        rule->setFrameShape(QFrame::HLine);
        rule->setFrameShadow(QFrame::Plain);
        aaApplyHairline(rule, palette());
        auto *empty = new QLabel;
        empty->setAlignment(Qt::AlignCenter);
        empty->setWordWrap(true);
        empty->setContentsMargins(kSpaceLg, kSpaceLg, kSpaceLg, kSpaceLg);
        empty->setForegroundRole(QPalette::PlaceholderText);
        v->addWidget(h);
        v->addWidget(rule);
        // The rows are links and nothing says so: a plain list row and a
        // clickable one are drawn the same, and the whole point of the
        // overview is the jump to the item's own page.
        auto *hint = hintLabel(
            QStringLiteral("Click a row to open it on its own page, with it selected")
        );
        hint->setContentsMargins(kSpaceLg, kSpaceXs, kSpaceLg, kSpaceXs);
        v->addWidget(hint);
        v->addWidget(tree, 1);
        v->addWidget(empty, 1);
        *emptyOut = empty;
        return w;
    }

    QWidget *buildSettings() {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(kSpaceLg, kSpaceLg, kSpaceLg, kSpaceLg);
        v->setSpacing(kSpaceLg);
        auto *row = new QHBoxLayout;
        row->setSpacing(kSpaceLg * 2);

        auto scanCol = section(QStringLiteral("Scan"));
        auto *scanHint = hintLabel(
            QStringLiteral(
                "This Linux scan lists leftover folders, unused packages, and outdated packages. Installed system apps are not part of this scan."
            )
        );
        scanCol.second->addWidget(scanHint);

        auto delCol = section(QStringLiteral("Deletion"));
        m_confirmBox = new QCheckBox(QStringLiteral("Confirm before running"));
        m_confirmBox->setChecked(true);
        auto *delHint = hintLabel(
            QStringLiteral("Shows an alert before rm, package remove, or updates.")
        );
        delCol.second->addWidget(m_confirmBox);
        delCol.second->addWidget(delHint);

        auto ignCol = section(QStringLiteral("Ignored leftovers"));
        QFont small = aaSmallFont();
        auto *ignListHost = new QWidget;
        auto *ilv = new QVBoxLayout(ignListHost);
        ilv->setContentsMargins(0, 0, 0, 0);
        ilv->setSpacing(kSpaceXs);
        m_ignoredEmpty = hintLabel(
            QStringLiteral("None. Ignore a leftover from its inspector to hide it on later scans.")
        );
        // Every hidden path is listed, not the first twelve: the list is where a
        // hidden leftover comes back, and a path the reader cannot see is one
        // they cannot restore.
        m_ignoredList = new QListWidget;
        m_ignoredList->setFont(small);
        m_ignoredList->setToolTip(
            QStringLiteral("Select a path, then press Show Again, to show that leftover in the list")
        );
        m_ignoredList->setAccessibleName(QStringLiteral("Hidden leftovers"));
        m_ignoredList->setMaximumHeight(aaRowPx(m_ignoredList) * 6 + 8);
        m_ignoredList->setMinimumWidth(220);
        aaApplySourceList(m_ignoredList);
        ilv->addWidget(m_ignoredEmpty);
        ilv->addWidget(m_ignoredList, 1);
        // The double click is the quick way in, but it is a gesture nothing on
        // screen names. The button is the visible way back, for a path the
        // reader cannot double-click, and for a pointer or keyboard that
        // never sends one.
        auto *ignHint = hintLabel(
            QStringLiteral(
                "Select a path, then press Show Again, to show that leftover in the list."
            )
        );
        ilv->addWidget(ignHint);
        auto *ignButtons = new QHBoxLayout;
        ignButtons->setContentsMargins(0, 0, 0, 0);
        ignButtons->setSpacing(kSpaceSm);
        m_showIgnored = new QPushButton(QStringLiteral("Show Again"));
        m_showIgnored->setToolTip(
            QStringLiteral("Show the selected ignored leftover in the list again")
        );
        m_showIgnored->setEnabled(false);
        ignButtons->addWidget(m_showIgnored);
        ignButtons->addStretch();
        ilv->addLayout(ignButtons);
        m_clearIgnored = new QPushButton(QStringLiteral("Clear ignored leftovers"));
        m_clearIgnored->setToolTip(QStringLiteral("Show every ignored leftover in the list again"));
        ignCol.second->addWidget(ignListHost, 1);
        ignCol.second->addWidget(m_clearIgnored);
        /* The backup is the only copy of this list once settings.json stops
           reading, and there is no other way back to it: a settings file that
           will not parse is one the window refuses to overwrite, so the list
           cannot be retyped by saving over it. The button is here rather than
           only in the error bar because that bar is dismissible, and a
           dismissed bar would leave the list unreachable. Disabled with the
           reason on the tooltip when there is nothing to put back. */
        m_restoreSettings = new QPushButton(QStringLiteral("Restore settings from backup"));
        m_restoreSettings->setToolTip(QStringLiteral(
            "Put settings.json.bak back in place of the settings file, and keep the file "
            "being replaced as settings.json.bad"
        ));
        ignCol.second->addWidget(m_restoreSettings);

        row->addWidget(scanCol.first, 1);
        row->addWidget(delCol.first, 1);
        row->addWidget(ignCol.first, 1);
        v->addLayout(row);
        v->addStretch();
        auto *ver = new QLabel(QStringLiteral("AppAttic " APPATTIC_VERSION));
        ver->setFont(small);
        ver->setForegroundRole(QPalette::PlaceholderText);
        v->addWidget(ver);

        connect(m_confirmBox, &QCheckBox::toggled, this, [this](bool on) {
            m_confirmDelete = on;
            persistSettings();
        });
        connect(m_clearIgnored, &QPushButton::clicked, this, [this] {
            const int n = m_ignored.size();
            m_ignored.clear();
            persistSettings();
            fillCurrent();
            const QString shown =
                QStringLiteral("Shown in the list again: %1.").arg(localeCount(n));
            statusBar()->showMessage(shown);
            // The list emptied under the button; the count that reports it
            // lives in the status bar, which is silent to a screen reader.
            aaAnnounce(m_ignoredList, shown);
        });
        connect(m_ignoredList, &QListWidget::currentItemChanged, this,
                [this](QListWidgetItem *it, QListWidgetItem *) {
                    if (m_showIgnored) m_showIgnored->setEnabled(it != nullptr);
                });
        connect(m_showIgnored, &QPushButton::clicked, this, [this] {
            QListWidgetItem *it = m_ignoredList->currentItem();
            if (!it) return;
            restoreIgnoredLeftover(it->data(Qt::UserRole).toString(), it->text());
        });
        connect(m_ignoredList, &QListWidget::itemActivated, this, [this](QListWidgetItem *it) {
            if (!it) return;
            restoreIgnoredLeftover(it->data(Qt::UserRole).toString(), it->text());
        });
        connect(m_restoreSettings, &QPushButton::clicked, this, [this] {
            restoreSettingsFromBackup();
        });
        return w;
    }

    std::pair<QWidget *, QVBoxLayout *> section(const QString &title) {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(0, 0, 0, 0);
        v->setSpacing(kSpaceSm);
        auto *t = new QLabel(title);
        t->setFont(aaSectionFont());
        v->addWidget(t);
        return {w, v};
    }

    QLabel *hintLabel(const QString &text) {
        auto *l = new QLabel(text);
        l->setFont(aaSmallFont());
        l->setWordWrap(true);
        l->setForegroundRole(QPalette::PlaceholderText);
        return l;
    }

    /// The rows of `page` the list shows, in the order it shows them. Every
    /// predicate `visibleRows` applies is here, so a caller that needs the same
    /// set can ask for it without re-deriving them.
    ///
    /// `sorted` is off for callers that only count or test membership in the
    /// set: sorting copies a `Finding` per comparison and collates names, which
    /// buys an order those callers throw away. The sort is the expensive half
    /// of this function, and it used to run on every checkbox toggle.
    QVector<Finding> filteredRows(Page page, bool sorted) const {
        QVector<Finding> rows;
        const QString q = searchFold(m_search->text().trimmed());
        const QString filt = m_filter->currentData().toString();
        const bool needQ = !q.isEmpty();
        for (const Finding &f : m_findings) {
            if (!matchPage(f, page)) continue;
            if (page == Page::Leftovers && leftoverIsIgnored(f, m_ignored)) continue;
            if (page == Page::Packages) {
                if (filt == QLatin1String("globals") && !isGlobalKind(f)) continue;
                if (filt == QLatin1String("leaves") && isGlobalKind(f)) continue;
            }
            if (needQ && !searchHaystack(f).contains(q)) continue;
            rows.push_back(f);
        }
        if (!sorted) return rows;
        // Largest first, then a total order. Size alone is not one: every
        // 4 KB directory and every unmeasured row carries the same bytes and
        // `std::sort` is not stable, so the same scan filled the table in a
        // different order on the next run.
        // `QCollator` orders the labels by the locale's rules rather than by
        // UTF-16 code unit, which files "Ä" after "Z" in a byte-order compare;
        // the C locale has no rules and keeps the code-unit order. The path
        // breaks the next tie and the row identity the last one, the same
        // order `sortChildrenWith` in diskusage.cpp gives the children.
        const QLocale locale;
        const bool collated = locale.name() != QLatin1String("C");
        const QCollator collator(locale);
        std::sort(rows.begin(), rows.end(), [collated, &collator](const Finding &a, const Finding &b) {
            if (a.bytes != b.bytes) return a.bytes > b.bytes;
            if (collated) {
                const int c = collator.compare(a.name, b.name);
                if (c != 0) return c < 0;
            } else {
                const int c = a.name.compare(b.name, Qt::CaseInsensitive);
                if (c != 0) return c < 0;
            }
            if (a.path != b.path) return a.path < b.path;
            return a.uid() < b.uid();
        });
        return rows;
    }

    QVector<Finding> visibleRows(Page page) const {
        return filteredRows(page, true);
    }

    int countPage(Page page) const {
        int n = 0;
        for (const Finding &f : m_findings) {
            if (!matchPage(f, page)) continue;
            if (page == Page::Leftovers && leftoverIsIgnored(f, m_ignored)) continue;
            ++n;
        }
        return n;
    }

    void fillCurrent() {
        const Page page = currentPage();
        if (m_pageTitle) m_pageTitle->setText(pageTitle(page));
        // The title bar and the task switcher entry name the page too, so the
        // window a screenshot or an alt-tab shows says where the user is.
        setWindowTitle(pageTitle(page) + QStringLiteral(" · AppAttic"));
        refreshSidebarCounts();
        const bool settings = page == Page::Settings;
        const bool overview = page == Page::Overview;
        const bool disk = page == Page::DiskUsage;
        m_stack->setCurrentIndex(settings ? 2 : (overview ? 0 : (disk ? 3 : 1)));
        const bool list = !settings && !overview && !disk;
        const bool scanLive = m_scanning && !m_scanPhase.isEmpty();
        const auto vis = [](QAction *act, QWidget *w, bool on) {
            if (act) act->setVisible(on);
            if (w) w->setVisible(on);
        };
        vis(m_searchAct, m_search, list);
        vis(m_filterAct, m_filter, page == Page::Packages);
        vis(m_selectAllAct, m_selectAll, list);
        vis(m_rescanAct, m_rescan, !settings && !disk);
        vis(m_countAct, m_count, list || overview || scanLive);
        vis(m_scanBarAct, m_scanBar, scanLive);
        /* The search box and the Kind box belong to the page that is on screen.
           Both were left holding their value when the window left the list, so
           a term typed on Leftovers was still filtering Outdated on the way
           back in, with no box on screen to say so: the page read "No outdated
           packages match this search" and the sidebar badge read a count the
           list did not have. A filter that outlives the control that set it
           has no path off, so both go with the page. */
        if (!list) clearListFilters();
        if (overview) fillOverview();
        else if (list) fillTable(page);
        else if (settings) refreshIgnoredList();
        refreshActionBar();
    }

    void refreshSidebarCounts() {
        const int counts[] = {
            0,
            countPage(Page::Leftovers),
            countPage(Page::Stale),
            countPage(Page::Outdated),
            countPage(Page::Packages),
            0,
        };
        for (int i = 0; i < 6; ++i) {
            QListWidgetItem *it = m_sidebar->item(i);
            if (!it) continue;
            it->setData(Qt::UserRole, counts[i]);
        }
        m_sidebar->viewport()->update();
    }

    /// The list-page toolbar filters, reset together. Both are cleared under a
    /// signal blocker: their own connections refill the page, and this runs
    /// inside that refill.
    void clearListFilters() {
        if (m_filter && m_filter->currentIndex() != 0) {
            const QSignalBlocker block(m_filter);
            m_filter->setCurrentIndex(0);
        }
        if (m_search && !m_search->text().isEmpty()) {
            const QSignalBlocker block(m_search);
            m_search->clear();
        }
    }

    void fillOverview() {
        const Tone t = toneFrom(palette());
        const int leftovers = countPage(Page::Leftovers);
        const int stale = countPage(Page::Stale);
        const int outdated = countPage(Page::Outdated);
        const int packages = countPage(Page::Packages);
        qint64 leftoverBytes = 0;
        bool leftoverSized = false;
        for (const Finding &f : m_findings) {
            if (!matchPage(f, Page::Leftovers) || leftoverIsIgnored(f, m_ignored)) continue;
            if (f.bytes < 0) continue;
            leftoverSized = true;
            leftoverBytes = addSatBytes(leftoverBytes, f.bytes);
        }
        const bool scanningEmpty = emptyScanPending();
        const bool settingsBlocked = m_settingsError && !m_hasScanned && m_findings.isEmpty() && !m_scanning;
        const QString pending = QStringLiteral("…");
        const QString blockedMark = QStringLiteral("-");
        // The Linux scan has no installed-app count to show, and a scan cannot
        // fill this one in. "Not scanned" read as a failed measurement next to
        // four real numbers; the marker says the value does not exist here.
        m_statInstalled->setText(QStringLiteral("n/a"));
        m_statInstalled->setToolTip(
            QStringLiteral("This Linux scan does not count installed apps.")
        );
        auto statCount = [&](int n) {
            if (scanningEmpty) return pending;
            if (settingsBlocked) return blockedMark;
            return localeCount(n);
        };
        m_statLeftovers->setText(statCount(leftovers));
        {
            QPalette p = m_statLeftovers->palette();
            p.setColor(QPalette::WindowText, (!scanningEmpty && !settingsBlocked && leftovers) ? t.red : t.text);
            m_statLeftovers->setPalette(p);
        }
        m_statLeftoverData->setText(
            scanningEmpty ? pending
                          : (settingsBlocked ? blockedMark
                                             : (leftovers > 0 && !leftoverSized
                                                    ? QStringLiteral("unknown")
                                                    : humanSize(leftoverBytes)))
        );
        m_statStale->setText(statCount(stale));
        m_statOutdated->setText(statCount(outdated));
        m_statPackages->setText(statCount(packages));
        m_statInstalled->setFont(aaBodyFont());
        m_statInstalled->setForegroundRole(QPalette::PlaceholderText);
        m_statScan->setText(
            scanningEmpty ? pending
                          : (m_scanAt.isEmpty() ? QStringLiteral("Never") : m_scanAt)
        );

        auto fillOv = [&](QTreeWidget *tree, QLabel *empty, Page page, const QString &emptyText) {
            tree->clear();
            QVector<Finding> rows;
            for (const Finding &f : m_findings) {
                if (!matchPage(f, page)) continue;
                if (page == Page::Leftovers && leftoverIsIgnored(f, m_ignored)) continue;
                rows.push_back(f);
            }
            std::sort(rows.begin(), rows.end(), [](const Finding &a, const Finding &b) {
                if (a.bytes != b.bytes) return a.bytes > b.bytes;
                return a.uid() < b.uid();
            });
            const int n = qMin(12, rows.size());
            for (int i = 0; i < n; ++i) {
                const Finding &f = rows[i];
                auto *it = new QTreeWidgetItem(tree);
                it->setText(0, displayName(f));
                it->setText(1, whatText(f, page));
                if (page == Page::Outdated) {
                    it->setText(2, outdatedVersionLabel(f));
                } else {
                    it->setText(2, f.bytes >= 0 ? humanSize(f.bytes) : QStringLiteral("unknown"));
                }
                it->setData(0, Qt::UserRole, f.uid());
                it->setToolTip(0, plainTooltip(displayName(f)));
                it->setToolTip(1, plainTooltip(whatText(f, page)));
                if (!f.path.isEmpty()) it->setToolTip(2, plainTooltip(f.path));
                if (page != Page::Outdated) {
                    it->setFont(2, aaNumericFont());
                    it->setTextAlignment(2, Qt::AlignTrailing | Qt::AlignVCenter);
                }
                it->setForeground(1, t.dim);
                it->setForeground(2, t.dim);
            }
            if (QTreeWidgetItem *head = tree->headerItem()) {
                // The header has to agree with the cells below it.
                head->setTextAlignment(
                    2,
                    page == Page::Outdated ? (Qt::AlignLeading | Qt::AlignVCenter)
                                           : (Qt::AlignTrailing | Qt::AlignVCenter)
                );
            }
            const QString text = settingsBlocked
                ? QStringLiteral("Settings could not be loaded.")
                : (scanningEmpty ? QStringLiteral("Scanning…") : emptyText);
            empty->setText(text);
            empty->setVisible(n == 0);
            tree->setVisible(n > 0);
        };
        fillOv(
            m_ovLeftovers,
            m_ovLeftEmpty,
            Page::Leftovers,
            QStringLiteral("No leftover data from uninstalled apps.")
        );
        fillOv(
            m_ovStale,
            m_ovStaleEmpty,
            Page::Stale,
            QStringLiteral("No unused installed apps in this scan.")
        );
        fillOv(
            m_ovOutdated,
            m_ovOutEmpty,
            Page::Outdated,
            QStringLiteral("No outdated packages in this scan.")
        );
        m_count->setText(m_scanning ? scanStatusText() : QString());
    }

    QStringList pageHeaders(Page page) const {
        switch (page) {
        case Page::Leftovers:
            return {QString(), QStringLiteral("Name"), QStringLiteral("Location"),
                    QStringLiteral("Modified"), QStringLiteral("Size")};
        case Page::Stale:
            return {QString(), QStringLiteral("Name"), QStringLiteral("Status"),
                    QStringLiteral("Last used"), QStringLiteral("Size")};
        case Page::Outdated:
            return {QString(), QStringLiteral("Name"), QStringLiteral("Manager"),
                    QStringLiteral("Current \u2192 Latest")};
        case Page::Packages:
            return {QString(), QStringLiteral("Name"), QStringLiteral("Manager"),
                    QStringLiteral("Kind"), QStringLiteral("Size")};
        default:
            return {QString(), QStringLiteral("Name")};
        }
    }

    void setupColumns(Page page, const QStringList &headers) {
        // Qt samples this many rows per column when sizing; 1000 (the default)
        // cost 17 ms of a 2000 row fill, 100 costs 1 ms. The auto-sized columns
        // hold short labels, so a sampled maximum is enough.
        m_table->header()->setResizeContentsPrecision(100);
        m_table->header()->setSectionResizeMode(0, QHeaderView::Fixed);
        m_table->setColumnWidth(0, page == Page::Leftovers ? 36 : 28);
        for (int c = 1; c < headers.size(); ++c) {
            // Interactive here, sized once per fill: ResizeToContents re-measures
            // its columns on every insertion.
            m_table->header()->setSectionResizeMode(c, QHeaderView::Interactive);
        }
        // Only the last column takes the slack. Stretching Name instead left a
        // wide hole between it and the values, which hugged the right edge.
        if (headers.size() > 1) {
            m_table->header()->setSectionResizeMode(headers.size() - 1, QHeaderView::Stretch);
        }
    }

    /// Per-fill constants for `cellData`: font, colours and page never change
    /// between rows, so they are built once and captured by the model.
    struct CellCtx {
        Page page;
        Tone tone;
        QFont nums;
        QColor dim;
        QColor amber;
        QColor highlight;
    };

    /// One cell of the findings table. The model asks for painted rows only, so
    /// this is not the per-row loop it replaced.
    QVariant cellData(const CellCtx &ctx, const Finding &f, const QString &child, int column,
                      int role) const {
        const Page page = ctx.page;
        const QString uid = f.uid();
        const bool markedCleanup = m_marked.contains(uid);
        const bool markedKeep = m_markedManual.contains(uid);
        if (!child.isEmpty()) {
            const bool childMarked = m_marked.contains(packageChildMarkKey(uid, child));
            if (column == 0) {
                if (role == Qt::DisplayRole) return childMarked ? QStringLiteral("in") : QString();
                if (role == Qt::ForegroundRole) return ctx.highlight;
                if (role == Qt::SizeHintRole) return QSize(28, 0);
                if (role == Qt::ToolTipRole) {
                    return childMarked
                               ? QStringLiteral("Included. Click to remove from the selection.")
                               : QStringLiteral("Click to include this dependency in remove.");
                }
                return {};
            }
            if (column == 1) {
                if (role == Qt::DisplayRole) return child;
                if (role == Qt::ForegroundRole) return ctx.dim;
            }
            return {};
        }
        const QString name = displayName(f);
        if (column == 0) {
            const bool checkable = page == Page::Leftovers && canMarkCleanup(f, page);
            switch (role) {
            case Qt::DisplayRole:
                if (checkable) return QString();
                return (markedCleanup || markedKeep) ? QStringLiteral("in") : QString();
            case Qt::CheckStateRole:
                if (!checkable) return {};
                return int(markedCleanup ? Qt::Checked : Qt::Unchecked);
            case Qt::ForegroundRole:
                return ctx.highlight;
            case Qt::SizeHintRole:
                return QSize(page == Page::Leftovers ? 36 : 28, 0);
            case Qt::ToolTipRole:
                if (markedCleanup) {
                    return page == Page::Leftovers
                               ? QStringLiteral("Included. Untick to remove from the selection.")
                               : QStringLiteral("Included. Click to remove from the selection.");
                }
                if (markedKeep) {
                    return QStringLiteral(
                        "Marked as manually installed. Click to remove from the selection."
                    );
                }
                if (canMarkCleanup(f, page)) {
                    return page == Page::Leftovers
                               ? QStringLiteral("Tick to include in cleanup.")
                               : QStringLiteral("Click to include in cleanup, update, or remove.");
                }
                return QString();
            default:
                return {};
            }
        }
        if (column == 1) {
            if (role == Qt::DisplayRole) return name;
            if (role == Qt::ToolTipRole) {
                // `QToolTip` reads a string that starts with a tag as markup, so
                // a directory named `<b>Firefox</b>` renders as bold Firefox and
                // the tooltip stops naming a directory that exists. The name and
                // the path are filesystem text, so this is the same escaping the
                // preview trees do at 1687-1689.
                return plainTooltip(f.path.isEmpty() ? name : name + QLatin1Char('\n') + f.path);
            }
            if (role == Qt::ForegroundRole && page == Page::Leftovers && isShadowFinding(f)) {
                return ctx.amber;
            }
            return {};
        }
        const QVariant size = f.bytes >= 0 ? QVariant(humanSize(f.bytes))
                                           : QVariant(QStringLiteral("unknown"));
        /* The name column carries the full text as a tooltip, so a cell the
           width elides is still readable there. Every other column did not,
           and a long path, manager or version has nowhere else to read. The
           display text is the tooltip for the same reason: one string, no
           second wording to fall out of step with the cell. */
        const bool text = role == Qt::DisplayRole || role == Qt::ToolTipRole;
        // Same string, two roles, and only the tooltip one is read as markup:
        // a leftover path or a version starting with `<` is eaten by the
        // tooltip's rich-text guess. The cell paints the raw text either way.
        const auto shown = [role](const QVariant &v) {
            return role == Qt::ToolTipRole && v.canConvert<QString>() && !v.isNull()
                       ? QVariant(plainTooltip(v.toString()))
                       : v;
        };
        switch (page) {
        case Page::Leftovers:
            if (text) {
                if (column == 2) return shown(locationLabel(f));
                if (column == 3) return shown(modifiedLabel(f));
                if (column == 4) return shown(size);
            }
            if (role == Qt::ForegroundRole) {
                if (column == 2 && isShadowFinding(f)) return ctx.amber;
                if (column >= 2) return ctx.dim;
            }
            break;
        case Page::Stale:
            if (text) {
                if (column == 2) return shown(statusLabel(f));
                if (column == 3) return shown(modifiedLabel(f));
                if (column == 4) return shown(size);
            }
            if (role == Qt::ForegroundRole) {
                if (column == 2) return statusColor(f, ctx.tone, page);
                if (column >= 3) return ctx.dim;
            }
            break;
        case Page::Outdated:
            if (text) {
                if (column == 2) return shown(managerLabel(f));
                if (column == 3) return shown(outdatedVersionLabel(f));
            }
            if (role == Qt::ForegroundRole) {
                if (column == 2) return ctx.dim;
                if (column == 3) return ctx.amber;
            }
            break;
        case Page::Packages:
            if (text) {
                if (column == 2) return shown(managerLabel(f));
                if (column == 3) return shown(humanKind(f.kind));
                if (column == 4) return shown(size);
            }
            if (role == Qt::ForegroundRole) {
                if (column == 2) return ctx.dim;
                if (column == 3) return statusColor(f, ctx.tone, page);
                if (column == 4) return ctx.dim;
            }
            break;
        default:
            break;
        }
        if (role == Qt::FontRole && column == 4) return ctx.nums;
        if (role == Qt::TextAlignmentRole && column == 4) return int(Qt::AlignTrailing | Qt::AlignVCenter);
        return {};
    }

    /// Flip a row's check state from the view. The inspector checkbox and a
    /// click in column 0 both land here.
    void toggleRowMark(const Finding &f, const QString &child, bool on) {
        // While a scan or a cleanup script runs, the selection is read by that
        // run: the script is built from it, and a rescan prunes it. Accepting
        // clicks then left the "N selected" count moving under a button that
        // runs something else.
        if (m_scanning) return;
        const Page page = currentPage();
        const QString uid = f.uid();
        if (!child.isEmpty()) {
            if (page != Page::Packages) return;
            if (packageChildCommand(f, child).isEmpty()) return;
            const QString key = packageChildMarkKey(uid, child);
            if (on) m_marked.insert(key);
            else m_marked.remove(key);
            m_model->refreshUid(uid, child);
            refreshMarkChrome();
            return;
        }
        if (on) {
            if (!canMarkCleanup(f, page)) return;
            m_marked.insert(uid);
            m_markedManual.remove(uid);
        } else {
            m_marked.remove(uid);
        }
        m_model->refreshUid(uid);
        refreshMarkChrome();
        if (uid == m_selectedUid) rebuildInspector();
    }

    void fillTable(Page page) {
        const Tone tone = toneFrom(palette());
        const QVector<Finding> rows = visibleRows(page);
        const QStringList headers = pageHeaders(page);
        bool hasKids = false;
        for (const Finding &f : rows) {
            if (!f.children.isEmpty()) {
                hasKids = true;
                break;
            }
        }
        m_table->setRootIsDecorated(hasKids && page == Page::Packages);
        m_table->setIndentation(hasKids && page == Page::Packages ? 18 : 0);
        const CellCtx ctx{
            page,
            tone,
            aaNumericFont(),
            tone.dim,
            tone.amber,
            palette().color(QPalette::Highlight),
        };
        const bool checkboxColumn = page == Page::Leftovers;
        m_model->setContent(
            headers,
            page == Page::Outdated ? -1 : headers.size() - 1,
            checkboxColumn
                ? QStringLiteral("Tick to include the leftover in cleanup")
                : QStringLiteral("Click to include the item in cleanup, update, or remove"),
            hasKids && page == Page::Packages,
            rows,
            [this, ctx](const Finding &f, const QString &child, int column, int role) {
                return cellData(ctx, f, child, column, role);
            },
            [this](const Finding &f, const QString &child, bool on) {
                toggleRowMark(f, child, on);
            }
        );
        // After the reset: the header has no sections to touch before the model
        // carries the columns, and Qt 6.4 crashes on setSectionResizeMode then.
        setupColumns(page, headers);
        // Columns sized once now that the model holds every row. The stretched
        // last column is left alone.
        for (int c = 1; c + 1 < headers.size(); ++c) m_table->resizeColumnToContents(c);
        QModelIndex select = m_model->indexOfUid(m_selectedUid, m_selectedChild);
        if (!select.isValid() && !rows.isEmpty()) select = m_model->index(0, 0, QModelIndex());
        finishFill(page, rows, select);
    }

    /// Shared tail of both fill paths: keep the selection on a visible row, then
    /// refresh the counters, the empty pane, the select-all label and the inspector.
    void finishFill(Page page, const QVector<Finding> &rows, const QModelIndex &select) {
        if (select.isValid()) {
            m_selectedUid = m_model->data(select, Qt::UserRole).toString();
            if (select.parent().isValid()) m_table->expand(select.parent());
            m_table->setCurrentIndex(select);
        } else {
            m_selectedUid.clear();
            m_selectedChild.clear();
        }

        const bool scanningEmpty = emptyScanPending();
        const bool scanFailed = emptyScanFailed();
        const bool settingsBlocked = m_settingsError && !m_hasScanned && m_findings.isEmpty() && !m_scanning;
        if (rows.isEmpty() && scanningEmpty) {
            m_table->show();
            m_emptyPane->hide();
            m_clearSearch->hide();
            m_emptyRetry->hide();
        } else if (rows.isEmpty()) {
            m_table->hide();
            m_emptyPane->show();
            if (settingsBlocked) {
                m_emptyTitle->setText(QStringLiteral("Settings could not be loaded"));
                m_emptyDetail->setText(
                    m_error->text().isEmpty()
                        ? QStringLiteral("Fix the settings file, then click Rescan.")
                        : m_error->text()
                );
            } else {
                m_emptyTitle->setText(pageEmptyTitle(page, scanningEmpty, scanFailed));
                m_emptyDetail->setText(
                    pageEmptyDetail(
                        page,
                        scanningEmpty,
                        scanFailed,
                        m_search->text(),
                        m_ignored.size(),
                        m_filter->currentData().toString(),
                        m_error->text()
                    )
                );
            }
            m_clearSearch->setVisible(
                !m_search->text().trimmed().isEmpty() && !scanningEmpty && !scanFailed && !settingsBlocked
            );
            // A settings error is fixed by editing the file, and Rescan reads
            // the same broken file again: offering the button there is a dead
            // end next to copy that says to fix the file.
            m_emptyRetry->setVisible(scanFailed && !scanningEmpty);
        } else {
            m_table->show();
            m_emptyPane->hide();
            m_clearSearch->hide();
            m_emptyRetry->hide();
        }
        m_inspectorScroll->setVisible(m_table->isVisible());
        QString count = countLabel(page, rows.size());
        if (scanningEmpty) {
            count = scanStatusText();
        } else if (m_scanning) {
            count += QStringLiteral(" · ") + scanStatusText();
        } else if (!m_scanAt.isEmpty()) {
            count += QStringLiteral(" · ") + m_scanAt;
        }
        m_count->setText(count);
        // The findings table is where the whole app is read out, and one widget
        // serves four list pages. Named per page here: a bare "tree" tells a
        // screen-reader user nothing about what they landed on, and this is
        // the one place that already knows the page.
        m_table->setAccessibleName(pageTitle(page) + QStringLiteral(" list"));
        bool anyMarkable = false;
        for (const Finding &f : rows) {
            if (canMarkCleanup(f, page)) {
                anyMarkable = true;
                break;
            }
        }
        m_selectAll->setText(allMarked(page, rows) ? QStringLiteral("Deselect All") : QStringLiteral("Select All"));
        const bool showSelect = anyMarkable && !scanningEmpty;
        if (m_selectAllAct) m_selectAllAct->setVisible(showSelect);
        m_selectAll->setVisible(showSelect);
        m_selectAll->setEnabled(showSelect && !m_scanning);
        if (m_table->isVisible()) rebuildInspector();
        else clearInspector();
    }

public:
    /// One scan against the host.exec fixtures, pumped to completion. The
    /// gates below all need exactly this.
    bool runFixtureScan() {
        qputenv("APPATTIC_HOST_EXEC_FIXTURE", "1");
        m_hasScanned = false;
        rescan();
        QElapsedTimer timer;
        timer.start();
        while (m_scanning && timer.elapsed() < 120000) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        }
        return !m_scanning;
    }

#ifndef NDEBUG
    /// Render every page offscreen and save it next to the link proof. The
    /// smoke checks fill widgets; only this paints them, and the PNGs are what
    /// layout review looks at.
    void startShots(const QString &dir) {
        QDir().mkpath(dir);
        m_shotDir = dir;
        m_shotExit = 0;
        m_shotPages = 0;
        if (!runFixtureScan()) {
            std::fprintf(stderr, "shot: scan did not finish\n");
            m_shotExit = 1;
        }
        m_shotQueue = {
            {Page::Overview, QStringLiteral("overview.png")},
            {Page::Leftovers, QStringLiteral("leftovers.png")},
            {Page::Stale, QStringLiteral("stale.png")},
            {Page::Outdated, QStringLiteral("outdated.png")},
            {Page::Packages, QStringLiteral("packages.png")},
            {Page::Settings, QStringLiteral("settings.png")},
            {Page::DiskUsage, QStringLiteral("disk.png")},
        };
        m_shotIndex = 0;
        shotNext();
    }

    void shotNext() {
        if (m_shotIndex >= m_shotQueue.size()) {
            std::fprintf(
                stdout,
                "shot: ok (pages=%d dir=%s)\n",
                m_shotPages,
                m_shotDir.toUtf8().constData()
            );
            std::fflush(stdout);
            QCoreApplication::exit(m_shotExit);
            return;
        }
        const QPair<Page, QString> shot = m_shotQueue.at(m_shotIndex);
        selectPage(shot.first);
        QTimer::singleShot(120, this, [this, shot] {
            repaint();
            QCoreApplication::processEvents();
            const QPixmap image = grab();
            m_shotIndex += 1;
            if (image.isNull() || image.size() != size()) {
                std::fprintf(
                    stderr,
                    "shot: %s painted %dx%d, window is %dx%d\n",
                    shot.second.toUtf8().constData(),
                    image.width(),
                    image.height(),
                    width(),
                    height()
                );
                m_shotExit = 1;
                QCoreApplication::exit(1);
                return;
            }
            if (!image.save(m_shotDir + QLatin1Char('/') + shot.second)) {
                std::fprintf(stderr, "shot: cannot write %s\n", shot.second.toUtf8().constData());
                m_shotExit = 1;
                QCoreApplication::exit(1);
                return;
            }
            m_shotPages += 1;
            shotNext();
        });
    }

    /// Disk gate: a folder scan must draw its finished folders as it goes, and
    /// must have drawn some before the final tree filled in.
    int smokeDiskStreamChecks() {
        QTemporaryDir dir;
        if (!dir.isValid()) {
            std::fprintf(stderr, "disk-stream: no temp dir\n");
            return 1;
        }
        for (int i = 0; i < 3; ++i) {
            const QString sub = dir.path() + QStringLiteral("/folder-%1").arg(i);
            if (!QDir().mkpath(sub)) {
                std::fprintf(stderr, "disk-stream: cannot create %s\n", sub.toUtf8().constData());
                return 1;
            }
            for (int k = 0; k < 2; ++k) {
                QFile f(sub + QStringLiteral("/file-%1.bin").arg(k));
                if (!f.open(QIODevice::WriteOnly)) return 1;
                f.write(QByteArray(8192 * (i + 1), 'x'));
            }
        }
        selectPage(Page::DiskUsage);
        m_diskPage->startScan(dir.path());
        QElapsedTimer timer;
        timer.start();
        while (m_diskPage->isScanning() && timer.elapsed() < 60000) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        }
        if (m_diskPage->isScanning()) {
            std::fprintf(stderr, "disk-stream: scan did not finish\n");
            return 1;
        }
        if (m_diskPage->streamedRows() != 3) {
            std::fprintf(
                stderr,
                "disk-stream: %d rows streamed, expected 3\n",
                m_diskPage->streamedRows()
            );
            return 1;
        }
        if (!m_diskPage->streamedBeforeFinish()) {
            std::fprintf(stderr, "disk-stream: rows arrived only after the scan\n");
            return 1;
        }
        if (m_diskPage->streamedSegments() != 3) {
            std::fprintf(
                stderr,
                "disk-stream: ring drew %d segments, expected 3\n",
                m_diskPage->streamedSegments()
            );
            return 1;
        }
        // The chart is painted by hand, so nothing but this gate proves it
        // takes focus and answers the keyboard. Before it had a key handler
        // the only way into it was a click, and a keyboard or screen-reader
        // user could not reach a single folder in the whole app.
        DiskChart *chart = m_diskPage->findChild<DiskChart *>();
        if (!chart) {
            std::fprintf(stderr, "disk-stream: the size chart is not on the page\n");
            return 1;
        }
        if (chart->focusPolicy() == Qt::NoFocus) {
            std::fprintf(stderr, "disk-stream: the size chart cannot take focus\n");
            return 1;
        }
        if (chart->accessibleName().isEmpty()) {
            std::fprintf(stderr, "disk-stream: the size chart has no accessible name\n");
            return 1;
        }
        {
            QVector<DiskNode *> landed;
            QObject::connect(chart, &DiskChart::nodeFocused, [&landed](DiskNode *n) {
                landed.append(n);
            });
            for (const int key : {Qt::Key_Down, Qt::Key_Down, Qt::Key_Up}) {
                QKeyEvent ev(QEvent::KeyPress, key, Qt::NoModifier);
                QApplication::sendEvent(chart, &ev);
            }
            if (landed.size() != 3) {
                std::fprintf(
                    stderr,
                    "disk-stream: arrow keys moved the chart cursor %d times, expected 3\n",
                    int(landed.size())
                );
                return 1;
            }
            // The cursor lands on a real folder of the scan, not on nothing.
            if (!landed.last() || landed.last()->name.isEmpty()) {
                std::fprintf(stderr, "disk-stream: the chart cursor did not reach a folder\n");
                return 1;
            }
            // The folder it lands on is announced: the description names it.
            if (chart->accessibleDescription().isEmpty()) {
                std::fprintf(
                    stderr,
                    "disk-stream: moving the chart cursor announced nothing\n"
                );
                return 1;
            }
            if (!chart->accessibleDescription().contains(landed.last()->name)) {
                std::fprintf(
                    stderr,
                    "disk-stream: the announcement does not name the folder under the cursor\n"
                );
                return 1;
            }
        }
        const bool resumed = m_diskPage->checkRescanResumes();
        std::fprintf(
            stdout,
            "disk-stream: %s (rows=%d segments=%d chart-keyboard=ok resume=%s)\n",
            resumed ? "ok" : "FAILED",
            m_diskPage->streamedRows(),
            m_diskPage->streamedSegments(),
            resumed ? "ok" : "failed"
        );
        return resumed ? 0 : 1;
    }

    /// Streaming gate: a fixture scan must publish rows more than once, and
    /// every row published early must still be in the final list.
    int smokeStreamChecks() {
        m_partialSeen = 0;
        m_partialRowsFirst = -1;
        m_partialUids.clear();
        if (!runFixtureScan()) {
            std::fprintf(stderr, "stream: scan did not finish\n");
            return 1;
        }
        if (m_partialSeen < 2) {
            std::fprintf(stderr, "stream: rows arrived in %d update(s)\n", m_partialSeen);
            return 1;
        }
        QSet<QString> final_uids;
        for (const Finding &f : m_findings) final_uids.insert(f.uid());
        for (const QString &uid : m_partialUids) {
            if (!final_uids.contains(uid)) {
                std::fprintf(
                    stderr,
                    "stream: row %s vanished from the final list\n",
                    uid.toUtf8().constData()
                );
                return 1;
            }
        }
        std::fprintf(
            stdout,
            "stream: ok (updates=%d rows=%d first=%d)\n",
            m_partialSeen,
            int(m_findings.size()),
            m_partialRowsFirst
        );
        return 0;
    }

    /// Keyboard gate for the overview panels. Every row there opens the page it
    /// came from, and both the hint under the column title and the table's
    /// accessible description tell the reader to press Enter. This drives the
    /// tree the way a keyboard user does: move the current row, send Return,
    /// and check the window left the overview for that item's page with the
    /// item selected. Without the `itemActivated` wiring the key did nothing
    /// and the overview was a pointer-only page.
    int smokeOverviewChecks() {
        const auto fail = [](const char *what) {
            std::fprintf(stderr, "overview-ui: %s\n", what);
            return 1;
        };
        m_findings.clear();
        for (int i = 0; i < 3; ++i) {
            Finding f;
            f.plugin = QStringLiteral("path-xdg-config");
            f.kind = QStringLiteral("orphan-dir");
            f.id = QStringLiteral("overview-%1").arg(i);
            f.status = QStringLiteral("orphaned");
            f.name = QStringLiteral("overview-app-%1").arg(i);
            f.path = QStringLiteral("/home/user/.config/overview-app-%1").arg(i);
            f.bytes = 1024 * (3 - i);
            f.mtime = QStringLiteral("2026-01-01T00:00:00Z");
            m_findings.push_back(f);
        }
        m_hasScanned = true;
        m_scanning = false;
        m_scanOk = true;
        selectPage(Page::Overview);
        if (m_ovLeftovers->topLevelItemCount() != 3) return fail("overview rows");

        // The biggest leftover sorts first, so the row the cursor lands on
        // after Down is the second one.
        m_ovLeftovers->setCurrentItem(m_ovLeftovers->topLevelItem(0));
        QKeyEvent down(QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier);
        QApplication::sendEvent(m_ovLeftovers, &down);
        QTreeWidgetItem *cursor = m_ovLeftovers->currentItem();
        if (!cursor || cursor != m_ovLeftovers->topLevelItem(1)) {
            return fail("Down did not move the overview cursor");
        }
        const QString uid = cursor->data(0, Qt::UserRole).toString();
        if (uid.isEmpty()) return fail("overview row carries no uid");
        QKeyEvent enter(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
        QApplication::sendEvent(m_ovLeftovers, &enter);
        if (currentPage() != Page::Leftovers) return fail("Enter did not open the leftovers page");
        if (m_selectedUid != uid) return fail("Enter did not carry the row's selection over");
        std::fprintf(
            stdout,
            "overview-ui: ok (rows=%d enter=ok)\n",
            m_ovLeftovers->topLevelItemCount()
        );
        return 0;
    }

    /// Widget-level check of the model-backed table. main.cpp owns the window,
    /// so this lives here instead of smoke.cpp: page switch, search, the mark
    /// toggle, selection restore and dependency rows all run through the model.
    int smokeTableChecks() {
        const auto fail = [](const char *what) {
            std::fprintf(stderr, "tables-ui: %s\n", what);
            return 1;
        };
        m_findings.clear();
        for (int i = 0; i < 200; ++i) {
            Finding f;
            f.plugin = QStringLiteral("path-xdg-config");
            f.kind = QStringLiteral("orphan-dir");
            f.id = QStringLiteral("table-%1").arg(i);
            f.status = QStringLiteral("orphaned");
            f.name = QStringLiteral("table-app-%1").arg(i);
            f.path = QStringLiteral("/home/user/.config/table-app-%1").arg(i);
            f.bytes = 1024 * (i + 1);
            f.mtime = QStringLiteral("2026-01-01T00:00:00Z");
            m_findings.push_back(f);
        }
        Finding pkg;
        pkg.plugin = QStringLiteral("flatpak");
        pkg.kind = QStringLiteral("app");
        pkg.id = QStringLiteral("pkg-1");
        pkg.name = QStringLiteral("pkg-app");
        pkg.status = QStringLiteral("installed");
        pkg.bytes = 4096;
        pkg.command = QStringLiteral("flatpak remove pkg-app");
        pkg.children = {QStringLiteral("libone"), QStringLiteral("libtwo")};
        m_findings.push_back(pkg);
        m_hasScanned = true;
        m_scanning = false;
        m_scanOk = true;

        selectPage(Page::Leftovers);
        if (m_model->rowCount() != 200) return fail("leftovers rows");
        if (m_model->columnCount() != 5) return fail("leftovers columns");
        // Sorted by size descending.
        const Finding biggest = m_model->rows().value(0);
        if (m_model->data(m_model->index(0, 1), Qt::DisplayRole).toString() != displayName(biggest)) {
            return fail("name cell");
        }
        if (m_model->data(m_model->index(0, 4), Qt::DisplayRole).toString()
            != humanSize(biggest.bytes)) {
            return fail("size cell");
        }
        const QModelIndex first = m_model->index(0, 0);
        if (!(m_model->flags(first) & Qt::ItemIsUserCheckable)) return fail("checkbox flag");
        if (!m_model->setData(first, int(Qt::Checked), Qt::CheckStateRole)) {
            return fail("toggle refused");
        }
        if (!m_marked.contains(biggest.uid())) return fail("toggle did not mark");
        if (m_model->data(first, Qt::CheckStateRole).toInt() != int(Qt::Checked)) {
            return fail("check state not painted");
        }
        // A run builds its script from the selection, so a busy window refuses
        // marks instead of moving the count under the button that runs it.
        const int marksBefore = m_marked.size();
        m_scanning = true;
        toggleRowMark(biggest, QString(), false);
        if (m_marked.size() != marksBefore) return fail("unmarked while busy");
        if (!m_marked.contains(biggest.uid())) return fail("busy mark dropped the selection");
        m_scanning = false;
        m_search->setText(QStringLiteral("table-app-1"));
        fillCurrent();
        if (m_model->rowCount() != 111) return fail("search rows");
        m_search->clear();
        fillCurrent();
        if (m_model->rowCount() != 200) return fail("rows after clearing search");
        /* A term typed on a list page must not still be filtering it when the
           window comes back from a page with no search box to clear it. */
        m_search->setText(QStringLiteral("table-app-1"));
        fillCurrent();
        selectPage(Page::DiskUsage);
        if (!m_search->text().isEmpty()) return fail("search survived leaving the list");
        if (m_filter->currentIndex() != 0) return fail("kind filter survived leaving the list");
        m_search->setText(QStringLiteral("table-app-1"));
        fillCurrent();
        if (m_model->rowCount() != 111) return fail("search rows after re-applying");
        m_search->clear();
        selectPage(Page::Leftovers);
        m_table->setCurrentIndex(m_model->index(3, 0));
        const QString selected = m_selectedUid;
        if (selected.isEmpty()) return fail("no selection");
        fillCurrent();
        if (m_selectedUid != selected) return fail("selection lost on refill");
        selectPage(Page::Packages);
        if (m_model->rowCount() != 1) return fail("packages rows");
        const QModelIndex pkgRow = m_model->indexOfUid(pkg.uid());
        if (!pkgRow.isValid()) return fail("package row missing");
        if (m_model->rowCount(pkgRow) != 2) return fail("child rows");
        const QModelIndex kid = m_model->index(0, 1, pkgRow);
        if (m_model->data(kid, Qt::DisplayRole).toString() != QLatin1String("libone")) {
            return fail("child name");
        }
        if (m_model->data(kid, Qt::UserRole + 1).toString() != QLatin1String("libone")) {
            return fail("child role");
        }
        if (m_model->parent(kid) != pkgRow) return fail("child parent");
        if (m_model->setData(kid, int(Qt::Checked), Qt::CheckStateRole)) {
            return fail("child row accepts a check state");
        }
        std::fprintf(
            stdout,
            "tables-ui: ok (rows=%d cols=%d children=%d)\n",
            m_model->rowCount(),
            m_model->columnCount(),
            m_model->rowCount(pkgRow)
        );
        return 0;
    }

private:
#endif

    void pruneStaleMarks() {
        QSet<QString> live;
        for (const Finding &f : m_findings) {
            if (canMarkCleanup(f, Page::Leftovers) || canMarkCleanup(f, Page::Stale)
                || canMarkCleanup(f, Page::Outdated) || canMarkCleanup(f, Page::Packages)) {
                live.insert(f.uid());
            }
            if (canMarkManual(f)) live.insert(f.uid());
            if (!isPackage(f)) continue;
            for (const QString &child : f.children) {
                if (!packageChildCommand(f, child).isEmpty()) {
                    live.insert(packageChildMarkKey(f.uid(), child));
                }
            }
        }
        m_marked.intersect(live);
        m_markedManual.intersect(live);
    }

    void refreshMarkChrome() {
        if (m_selectAll) {
            // The select-all label is a question about mark state over the page's
            // rows, not about their order, so it reads the unsorted filter
            // rather than `visibleRows`. Every checkbox toggle reaches here, and
            // `visibleRows` copies and collator-sorts every finding on the page
            // to answer a question the sort cannot change. The row set is the
            // one `visibleRows` builds, same predicates and same search.
            const QVector<Finding> rows = filteredRows(currentPage(), false);
            m_selectAll->setText(
                allMarked(currentPage(), rows)
                    ? QStringLiteral("Deselect All")
                    : QStringLiteral("Select All")
            );
        }
        refreshActionBar();
    }

    bool allMarked(Page page, const QVector<Finding> &rows) const {
        int n = 0;
        for (const Finding &f : rows) {
            if (!canMarkCleanup(f, page)) continue;
            if (!m_marked.contains(f.uid())) return false;
            ++n;
        }
        return n > 0;
    }

    QString countLabel(Page page, int n) const {
        switch (page) {
        case Page::Leftovers:
            return n == 1 ? QStringLiteral("1 leftover") : localeCount(n) + QStringLiteral(" leftovers");
        case Page::Stale:
            return n == 1 ? QStringLiteral("1 stale app") : localeCount(n) + QStringLiteral(" stale apps");
        case Page::Outdated:
            return n == 1 ? QStringLiteral("1 outdated package") : localeCount(n) + QStringLiteral(" outdated packages");
        case Page::Packages:
            return n == 1 ? QStringLiteral("1 package") : localeCount(n) + QStringLiteral(" packages");
        default:
            return localeCount(n);
        }
    }

    bool isScanPending() const {
        const bool noError = !m_error || m_error->text().isEmpty();
        return m_scanning || (!m_hasScanned && noError);
    }

    QString scanStatusText() const {
        if (m_scanPhase.isEmpty()) return QStringLiteral("Scanning…");
        if (m_scanTotal > 0 && m_scanIndex > 0) {
            return m_scanPhase
                + QStringLiteral(" (")
                + QString::number(m_scanIndex)
                + QLatin1Char('/')
                + QString::number(m_scanTotal)
                + QLatin1Char(')');
        }
        return m_scanPhase;
    }

    void applyScanProgressUi() {
        const QString msg = scanStatusText();
        statusBar()->showMessage(msg);
        if (m_count && m_scanning) m_count->setText(msg);
        const QString ov = QStringLiteral("Scanning…");
        if (m_scanning && m_ovLeftEmpty && m_ovLeftEmpty->isVisible()) {
            m_ovLeftEmpty->setText(ov);
        }
        if (m_scanning && m_ovStaleEmpty && m_ovStaleEmpty->isVisible()) {
            m_ovStaleEmpty->setText(ov);
        }
        if (m_scanning && m_ovOutEmpty && m_ovOutEmpty->isVisible()) {
            m_ovOutEmpty->setText(ov);
        }
        if (m_scanBar) {
            m_scanBar->setToolTip(msg);
            m_scanBar->setVisible(m_scanning && !m_scanPhase.isEmpty());
        }
    }

    /// A scan that has not answered yet and has nothing to show: the page says
    /// "Scanning", not "nothing found".
    bool emptyScanPending() const { return isScanPending() && m_findings.isEmpty(); }

    /// A finished scan that produced no findings and reported a failure: the
    /// page offers a retry instead of claiming there is nothing there.
    bool emptyScanFailed() const {
        return m_hasScanned && !m_scanning && !m_scanOk && m_findings.isEmpty();
    }

    QString emptyDetail(Page page) const {
        return pageEmptyDetail(
            page,
            emptyScanPending(),
            emptyScanFailed(),
            m_search->text(),
            m_ignored.size(),
            m_filter->currentData().toString(),
            m_error->text()
        );
    }

    QString whatText(const Finding &f, Page page) const {
        if (isShadowFinding(f) && !f.packagedPath.isEmpty()) {
            if (!f.summary.isEmpty()
                && f.summary.contains(QLatin1String("hides the packaged"), Qt::CaseInsensitive)) {
                return f.summary;
            }
            const bool desktop = f.kind.contains(QLatin1String("desktop"));
            const QString overlay = desktop
                ? QStringLiteral("desktop overlay")
                : QStringLiteral("PATH overlay");
            const QString name = displayName(f);
            if (name.isEmpty() || name == QLatin1String("-")) {
                QString cap = overlay;
                cap[0] = cap[0].toUpper();
                return cap + QStringLiteral(". Hides the packaged ") + f.packagedPath + QLatin1Char('.');
            }
            return name + QStringLiteral(" is a ") + overlay
                + QStringLiteral(". Hides the packaged ") + f.packagedPath + QLatin1Char('.');
        }
        if (!f.summary.isEmpty()) return f.summary;
        if (page == Page::Packages) {
            return humanKind(f.kind) + QStringLiteral(" · ") + managerLabel(f);
        }
        if (!f.kind.isEmpty()) return humanKind(f.kind);
        return f.plugin;
    }

    QString whyText(const Finding &f) const {
        if (isShadowFinding(f) && !f.packagedPath.isEmpty()) {
            if (!f.reason.isEmpty()
                && f.reason.contains(QLatin1String("package-manager file"), Qt::CaseInsensitive)) {
                return f.reason;
            }
            if (f.kind.contains(QLatin1String("desktop"))) {
                return QStringLiteral("This .desktop file takes precedence over the package-manager file ")
                    + f.packagedPath + QLatin1Char('.');
            }
            return QStringLiteral("This file is earlier on PATH than the package-manager file ")
                + f.packagedPath + QLatin1Char('.');
        }
        if (!f.reason.isEmpty()) return f.reason;
        if (!f.dialogBody.isEmpty()) return f.dialogBody;
        return QStringLiteral("Flagged by the ") + f.plugin + QStringLiteral(" plugin.");
    }

    const Finding *findingByUid(const QString &uid) const {
        for (const Finding &f : m_findings) {
            if (f.uid() == uid) return &f;
        }
        return nullptr;
    }

    void clearInspector() {
        m_factKeys.clear();
        while (QLayoutItem *item = m_inspectorLay->takeAt(0)) {
            if (item->widget()) item->widget()->deleteLater();
            delete item;
        }
    }

    /// One width for every fact key, from the widest label this inspector drew.
    /// Measuring one hardcoded English word instead truncates every other label
    /// the moment a translation is longer, and the uppercase pass widens them
    /// further (German "ß" uppercases to "SS").
    void sizeFactKeys() {
        const QFontMetrics fm(aaLabelFont());
        int px = 0;
        for (const QLabel *k : m_factKeys) {
            px = qMax(px, fm.horizontalAdvance(k->text()));
        }
        if (px <= 0) return;
        for (QLabel *k : m_factKeys) k->setFixedWidth(px + 12);
    }

    /// A named type role, never a point size: the inspector is built from the
    /// same scale as every other pane, so a size typed here would be the one
    /// level on this page that can drift from it.
    QLabel *inspectorLabel(const QString &text, const QFont &font, const QColor &color) {
        auto *l = new QLabel(text);
        l->setFont(font);
        // Plain text, not the AutoText default: the text carries a name read
        // off the filesystem, and a leftover directory called "<b>Firefox</b>"
        // is legal on Linux. Rich text renders it as bold Firefox with the
        // tags swallowed, which is a second spelling of a name the user is
        // about to be offered for removal.
        l->setTextFormat(Qt::PlainText);
        l->setWordWrap(true);
        l->setTextInteractionFlags(Qt::TextSelectableByMouse);
        QPalette p = l->palette();
        p.setColor(QPalette::WindowText, color);
        l->setPalette(p);
        return l;
    }

    void addFact(const QString &label, const QString &value, const QColor &color, bool mono = false) {
        auto *row = new QWidget;
        auto *h = new QHBoxLayout(row);
        h->setContentsMargins(0, 0, 0, 0);
        h->setSpacing(kSpaceMd);
        const Tone t = toneFrom(palette());
        auto *k = inspectorLabel(label.toUpper(), aaLabelFont(), t.dim);
        k->setAlignment(Qt::AlignTrailing | Qt::AlignTop);
        m_factKeys.append(k);
        auto *v = inspectorLabel(value, mono ? aaMonoFont() : aaBodyFont(), color);
        h->addWidget(k);
        h->addWidget(v, 1);
        m_inspectorLay->addWidget(row);
    }

    void rebuildInspector() {
        clearInspector();
        const Page page = currentPage();
        const Tone t = toneFrom(palette());
        const Finding *f = findingByUid(m_selectedUid);
        if (page == Page::Overview || page == Page::Settings || page == Page::DiskUsage) return;
        if (isScanPending() && m_findings.isEmpty()) {
            m_inspectorLay->addWidget(inspectorLabel(QStringLiteral("Scanning"), aaTitleFont(), t.text));
            m_inspectorLay->addWidget(inspectorLabel(
                !m_scanPhase.isEmpty()
                    ? scanStatusText()
                    : QStringLiteral("Results appear here when the scan finishes."),
                aaBodyFont(),
                t.dim
            ));
            m_inspectorLay->addStretch();
            return;
        }
        if (!f || !matchPage(*f, page)) {
            QString title = QStringLiteral("Select an item");
            QString body = QStringLiteral("What it is, why it was flagged, plus path and size.");
            // Unselected, so the question is only whether the page has any
            // rows at all. The unsorted filter answers it: sorting every
            // finding on the page to look at an empty/size result throws the
            // order away, and this runs on every selection change.
            if (filteredRows(page, false).isEmpty()) {
                title = emptyTitle(page);
                body = emptyDetail(page);
            } else if (page == Page::Leftovers) {
                title = QStringLiteral("Select a leftover");
            } else if (page == Page::Stale) {
                title = QStringLiteral("Select an app");
            } else if (page == Page::Outdated) {
                title = QStringLiteral("Select a package");
                body = QStringLiteral("What it is, why it is listed, plus current and latest versions.");
            } else if (page == Page::Packages) {
                title = QStringLiteral("Select a package");
                body = QStringLiteral("Orphan distro packages and user-global language tools. Remove or mark-manual after confirm.");
            }
            m_inspectorLay->addWidget(inspectorLabel(title, aaTitleFont(), t.text));
            m_inspectorLay->addWidget(inspectorLabel(body, aaBodyFont(), t.dim));
            m_inspectorLay->addStretch();
            return;
        }
        if (!m_selectedChild.isEmpty() && page == Page::Packages) {
            m_inspectorLay->addWidget(inspectorLabel(m_selectedChild, aaTitleFont(), t.text));
            addFact(QStringLiteral("What"), QStringLiteral("Dependency of %1").arg(displayName(*f)), t.text);
            addFact(QStringLiteral("Why"), QStringLiteral("Selected alone. Remove this package, not the parent tree."), t.text);
        } else {
            m_inspectorLay->addWidget(inspectorLabel(displayName(*f), aaTitleFont(), t.text));
            addFact(QStringLiteral("What"), whatText(*f, page), t.text);
            addFact(QStringLiteral("Why"), whyText(*f), t.text);
        }
        addFact(
            QStringLiteral("Kind"),
            f->kind.isEmpty() ? QStringLiteral("-") : humanKind(f->kind),
            t.text
        );
        addFact(
            QStringLiteral("Status"),
            statusLabel(*f),
            statusColor(*f, t, page)
        );
        if (!f->manager.isEmpty() || !f->engine.isEmpty()) {
            addFact(QStringLiteral("Manager"), managerLabel(*f), t.text);
        }
        if (!f->version.isEmpty()) addFact(QStringLiteral("Version"), f->version, t.text, true);
        if (!f->revision.isEmpty()) addFact(QStringLiteral("Revision"), f->revision, t.text, true);
        if (!f->currentVersion.isEmpty()) addFact(QStringLiteral("Current"), f->currentVersion, t.text, true);
        if (!f->latestVersion.isEmpty()) addFact(QStringLiteral("Latest"), f->latestVersion, t.amber, true);
        addFact(QStringLiteral("Size"), f->bytes >= 0 ? humanSize(f->bytes) : QStringLiteral("unknown"), t.text, true);
        // The Stale list calls this column "Last used", so the inspector does
        // too: one value, one name, whichever side of the window it is read on.
        addFact(
            page == Page::Stale ? QStringLiteral("Last used") : QStringLiteral("Modified"),
            modifiedLabel(*f),
            t.text
        );
        if (page == Page::Leftovers) {
            addFact(QStringLiteral("Location"), locationLabel(*f), isShadowFinding(*f) ? t.amber : t.text);
        }
        if (!f->path.isEmpty()) addFact(QStringLiteral("Path"), f->path, t.text, true);
        if (!f->extraPaths.isEmpty()) {
            addFact(QStringLiteral("Also"), f->extraPaths.join(QLatin1Char('\n')), t.text, true);
        }
        if (!f->packagedPath.isEmpty()) {
            addFact(QStringLiteral("Shadows"), f->packagedPath, t.amber, true);
        }
        if (!f->children.isEmpty()) addFact(QStringLiteral("Depends"), f->children.join(QLatin1Char('\n')), t.text, true);

        sizeFactKeys();
        m_inspectorLay->addStretch();

        if (!m_selectedChild.isEmpty() && page == Page::Packages) {
            const QString child = m_selectedChild;
            const QString uid = f->uid();
            const QString key = packageChildMarkKey(uid, child);
            auto *inc = new QCheckBox(QStringLiteral("Include this dependency in remove"));
            inc->setChecked(m_marked.contains(key));
            inc->setEnabled(!m_scanning && !packageChildCommand(*f, child).isEmpty());
            connect(inc, &QCheckBox::toggled, this, [this, uid, child, key](bool on) {
                if (on) m_marked.insert(key);
                else m_marked.remove(key);
                m_model->refreshUid(uid, child);
                refreshMarkChrome();
            });
            m_inspectorLay->addWidget(inc);
        } else if (canMarkCleanup(*f, page)) {
            auto *inc = new QCheckBox(
                page == Page::Outdated ? QStringLiteral("Include in update")
                                       : (page == Page::Packages ? QStringLiteral("Include in remove")
                                                                 : QStringLiteral("Include in cleanup"))
            );
            inc->setChecked(m_marked.contains(f->uid()));
            inc->setEnabled(!m_scanning);
            const QString uid = f->uid();
            connect(inc, &QCheckBox::toggled, this, [this, uid](bool on) {
                if (on) {
                    m_marked.insert(uid);
                    m_markedManual.remove(uid);
                } else {
                    m_marked.remove(uid);
                }
                m_model->refreshUid(uid);
                refreshMarkChrome();
            });
            m_inspectorLay->addWidget(inc);
        }
        if (page == Page::Packages && canMarkManual(*f)) {
            auto *keep = new QCheckBox(QStringLiteral("Mark as manually installed"));
            keep->setChecked(m_markedManual.contains(f->uid()));
            keep->setEnabled(!m_scanning);
            const QString uid = f->uid();
            connect(keep, &QCheckBox::toggled, this, [this, uid](bool on) {
                if (on) {
                    m_markedManual.insert(uid);
                    m_marked.remove(uid);
                } else {
                    m_markedManual.remove(uid);
                }
                m_model->refreshUid(uid);
                refreshMarkChrome();
            });
            m_inspectorLay->addWidget(keep);
        }
        if (!f->path.isEmpty()) {
            auto *reveal = new QPushButton(QStringLiteral("Show in Files"));
            const QString path = f->path;
            connect(reveal, &QPushButton::clicked, this, [path] {
                const QFileInfo fi(path);
                const QString dir = fi.isDir() ? path : fi.absolutePath();
                QDesktopServices::openUrl(QUrl::fromLocalFile(dir));
            });
            m_inspectorLay->addWidget(reveal);
        }
        if (page == Page::Leftovers) {
            auto *ign = new QPushButton(QStringLiteral("Ignore leftover"));
            const Finding copy = *f;
            connect(ign, &QPushButton::clicked, this, [this, copy] {
                for (const QString &k : leftoverIgnoreKeys(copy)) m_ignored.insert(pathIdentityKey(k));
                m_marked.remove(copy.uid());
                persistSettings();
                m_selectedUid.clear();
                fillCurrent();
                // The row is gone and the setting is written, so say so: the
                // only way back is the Settings page, and nothing on the list
                // page says the item was hidden rather than deleted.
                if (m_error->text().isEmpty()) {
                    const QString hidden =
                        QStringLiteral("Hidden %1 from the list. Restore it in Settings.")
                            .arg(displayName(copy));
                    statusBar()->showMessage(hidden);
                    // The row is gone and the status bar is not a live region,
                    // so a screen-reader user otherwise hears nothing at all
                    // after pressing the one button that removes a row.
                    aaAnnounce(m_stack, hidden);
                }
            });
            m_inspectorLay->addWidget(ign);
        }
    }

    QString emptyTitle(Page page) const {
        return pageEmptyTitle(page, emptyScanPending(), emptyScanFailed());
    }

    void refreshActionBar() {
        qint64 bytes = 0;
        int n = 0;
        int unsized = 0;
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid()) && !m_markedManual.contains(f.uid())) continue;
            ++n;
            if (f.bytes < 0) ++unsized;
            else bytes = addSatBytes(bytes, f.bytes);
        }
        const Page page = currentPage();
        m_actionBar->setVisible(
            n > 0 && page != Page::Overview && page != Page::Settings && page != Page::DiskUsage
        );
        m_actionCount->setText(QStringLiteral("%1 selected").arg(localeCount(n)));
        // A marked row with no measurement (`bytes < 0`) makes the total a
        // partial sum. Say so instead of printing the part that did measure as
        // the whole selection.
        QString bytesText;
        if (bytes > 0) {
            bytesText = humanSize(bytes);
            if (unsized > 0) bytesText += QStringLiteral(" (partial)");
        } else if (unsized > 0) {
            bytesText = QStringLiteral("unknown");
        }
        m_actionBytes->setText(bytesText);
        const bool busy = m_scanning;
        const bool canDelete = scriptHasCommands(cleanupScript());
        const bool canUpdate = scriptHasCommands(updateScript());
        const bool canKeep = scriptHasCommands(markManualScript());
        if (m_clearSel) m_clearSel->setEnabled(!busy);
        if (m_preview) m_preview->setEnabled(!busy);
        // Same rule as the row marks: nothing changes the selection while a
        // scan or script is running.
        if (m_selectAll) m_selectAll->setEnabled(!busy && m_selectAll->isVisible());
        m_deleteBtn->setVisible(canDelete);
        m_deleteBtn->setEnabled(canDelete && !busy);
        m_updateBtn->setVisible(canUpdate);
        m_updateBtn->setEnabled(canUpdate && !busy);
        m_markManualBtn->setVisible(canKeep);
        m_markManualBtn->setEnabled(canKeep && !busy);
    }

    int cleanupMarkCount() const {
        int n = 0;
        for (const Finding &f : m_findings) {
            if (isOutdated(f) && !isLeftover(f) && !isStale(f) && !isPackage(f)) continue;
            if (m_marked.contains(f.uid())) {
                ++n;
                continue;
            }
            if (!isPackage(f)) continue;
            for (const QString &child : f.children) {
                if (m_marked.contains(packageChildMarkKey(f.uid(), child))) ++n;
            }
        }
        return n;
    }

    int updateMarkCount() const {
        int n = 0;
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid()) || !isOutdated(f) || !f.updatable) continue;
            ++n;
        }
        return n;
    }

    static QString finishScript(QStringList header, const QStringList &body) {
        bool needRoot = false;
        for (const QString &line : body) {
            // A guarded removal escalates its action, so the call is not
            // always at the front of the line.
            if (line.startsWith(QLatin1String("rootcmd ")) || line.contains(QLatin1String("; then rootcmd ")))
                needRoot = true;
        }
        if (needRoot) header << scriptRootHelper();
        return (header + body).join(QLatin1Char('\n')) + QLatin1Char('\n');
    }

    static QStringList scriptHeader() {
        return {QStringLiteral("#!/bin/sh"), QStringLiteral("set -e"),
                QStringLiteral("# AppAttic. Review before running.")};
    }

    /// A plugin command is copied into the script as written. Refuse it and
    /// say so in the preview when it carries a character `/bin/sh` would act
    /// on: the row is left alone rather than run as an unquoted command.
    static QString scriptLine(const Finding &f, const QString &raw) {
        if (raw.isEmpty()) return {};
        if (!commandIsShellSafe(raw)) {
            return QStringLiteral("# skipped ") + f.plugin
                + QStringLiteral(": command is not shell-safe, refusing to run it");
        }
        // `rootcmd` is this file's own escalation wrapper, and only
        // `withRootCmd` writes it. A command that already carries the prefix
        // asked for itself, and `commandIsShellSafe` judges bytes, not the
        // program: the helper would run whatever it names as root.
        if (raw.startsWith(QLatin1String("rootcmd "))
            || raw.contains(QLatin1String("; then rootcmd "))) {
            return QStringLiteral("# skipped ") + f.plugin
                + QStringLiteral(": command asks for root escalation, refusing to run it");
        }
        return withRootCmd(raw);
    }

    QString cleanupScript() const {
        QStringList header = scriptHeader();
        QStringList body;
        for (const Finding &f : m_findings) {
            if (isOutdated(f) && !isLeftover(f) && !isStale(f) && !isPackage(f)) continue;
            if (m_marked.contains(f.uid())) {
                const QString raw = isLeftover(f) ? leftoverCleanupCommand(f) : f.command;
                const QString line = scriptLine(f, raw);
                if (line.isEmpty()) continue;
                body << line;
                continue;
            }
            if (!isPackage(f)) continue;
            for (const QString &child : f.children) {
                if (!m_marked.contains(packageChildMarkKey(f.uid(), child))) continue;
                const QString line = scriptLine(f, packageChildCommand(f, child));
                if (line.isEmpty()) continue;
                body << line;
            }
        }
        return finishScript(header, body);
    }

    QString updateScript() const {
        QStringList header = scriptHeader();
        QStringList body;
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid()) || !isOutdated(f)) continue;
            if (!f.updatable) continue;
            const QString raw = f.updateCommand.isEmpty() ? f.command : f.updateCommand;
            const QString line = scriptLine(f, raw);
            if (line.isEmpty()) continue;
            body << line;
        }
        return finishScript(header, body);
    }

    QString markManualScript() const {
        QStringList header = scriptHeader();
        header << QStringLiteral("# Mark as manually installed (keep)");
        QStringList body;
        for (const Finding &f : m_findings) {
            if (!m_markedManual.contains(f.uid())) continue;
            const QString raw = markManualCommand(f);
            if (raw.isEmpty()) continue;
            body << withRootCmd(raw);
        }
        return finishScript(header, body);
    }

    /// Body lines only. The `rootcmd` helper belongs to the script being merged
    /// into, not to the body appended to it: two copies redefine the same
    /// function and read like two different escalation paths.
    static QString scriptBodyLines(const QString &script) {
        QString out;
        bool inRootHelper = false;
        for (const QString &line : script.split(QLatin1Char('\n'))) {
            const QString t = line.trimmed();
            if (inRootHelper) {
                if (t == QLatin1String("}")) inRootHelper = false;
                continue;
            }
            if (t.isEmpty() || t.startsWith(QLatin1Char('#')) || t == QLatin1String("#!/bin/sh")
                || t.startsWith(QLatin1String("set "))) {
                continue;
            }
            if (t == QLatin1String("rootcmd() {")) {
                inRootHelper = true;
                continue;
            }
            out += line + QLatin1Char('\n');
        }
        return out;
    }

    /// True when a body line calls `rootcmd`, in either the bare or the guarded
    /// spelling `if q; then rootcmd action; fi`.
    static bool bodyNeedsRootHelper(const QString &body) {
        return body.startsWith(QLatin1String("rootcmd "))
            || body.contains(QLatin1String("\nrootcmd "))
            || body.contains(QLatin1String("; then rootcmd "));
    }

    QString previewAllScript() const {
        QString out = cleanupScript();
        if (scriptHasCommands(updateScript())) {
            const QString body = scriptBodyLines(updateScript());
            // The stripped body has no helper of its own. The merged script
            // keeps one, and it has to be there when the section being appended
            // is what escalates and the cleanup half does not.
            if (bodyNeedsRootHelper(body) && !bodyNeedsRootHelper(out)) {
                out += scriptRootHelper() + QLatin1Char('\n');
            }
            out += QStringLiteral("\n# Update selected packages\n");
            out += body;
        }
        if (scriptHasCommands(markManualScript())) {
            const QString body = scriptBodyLines(markManualScript());
            if (bodyNeedsRootHelper(body) && !bodyNeedsRootHelper(out)) {
                out += scriptRootHelper() + QLatin1Char('\n');
            }
            out += QStringLiteral("\n# Mark as manually installed. Delete in the UI does not run these lines.\n");
            out += body;
        }
        return out;
    }

    /* Hand a finished or failed script back to the event loop instead of
       deleting it here. Both handlers run inside `ScriptProcess`'s own signal
       emission, and `delete` would free the sender while the emission is still
       walking its connection list. Detaching first also keeps a handler that
       starts the next run from seeing the object it is being called from. */
    void retireScript() {
        ScriptProcess *done = m_script;
        m_script = nullptr;
        if (done) done->deleteLater();
    }

    void runScript(const QString &script, const QString &progress, const QString &done) {
        if (m_scanning) return;
        delete m_script;
        m_script = new ScriptProcess(this);
        QString writeError;
        if (!m_script->prepare(script, &writeError)) {
            delete m_script;
            m_script = nullptr;
            showError(writeError);
            return;
        }
        m_scanning = true;
        // The run reads the selection, so the inspector's include boxes go
        // with it: they are the same control as the column-0 mark, which the
        // busy rule already refuses.
        if (m_table->isVisible()) rebuildInspector();
        m_rescan->setEnabled(false);
        statusBar()->showMessage(progress);
        /* A package removal runs for as long as the package manager takes, and
           the disabled buttons were the only sign anything was happening. The
           same bar the scan uses, busy, so the window says "working" here too. */
        if (m_scanBar) {
            m_scanBar->setRange(0, 0);
            m_scanBar->setToolTip(progress);
            m_scanBar->show();
        }
        if (m_count) m_count->setText(progress);
        refreshActionBar();
        /* cordis-boundary: emission. The script mutates packages and files in
           other processes; it cannot be reverted, so it is withheld until the
           user confirms the preview (the commit point). A failure mid-run is
           reported as "commands before the failure may have already run"
           rather than faked as restored. */
        connect(m_script, &ScriptProcess::failed, this, [this]() {
            retireScript();
            m_scanning = false;
            m_rescan->setEnabled(true);
            if (m_scanBar) m_scanBar->hide();
            showError(QStringLiteral("Could not run the script."));
            refreshActionBar();
            if (m_table->isVisible()) rebuildInspector();
        });
        connect(m_script, &ScriptProcess::finished, this,
                [this, done](int code, bool stopped, const QByteArray &output) {
            m_scanning = false;
            m_rescan->setEnabled(true);
            if (m_scanBar) m_scanBar->hide();
            /* The script removed files, upgraded packages, or changed install
               state, on every outcome: a failure part-way through ran the lines
               before it. The CLI and the macOS UI reuse one scan snapshot, and
               its inventory stamp does not move for a file deleted inside a
               scanned directory, so it is dropped here rather than left to serve
               rows for what the script just removed.
               A removal that did not land is reported, not swallowed: a stale
               snapshot left on disk is exactly what makes the next CLI run
               list software that is gone. The two branches below build their
               own banner, so it is appended rather than shown on its own. */
            const bool cacheCleared = removeScanCacheFile(scanCacheFilePath());
            const QString cacheWarn = cacheCleared
                ? QString()
                : redactHomePaths(QStringLiteral(
                    "The scan snapshot at %1 could not be removed, so the next run may list items "
                    "this script already removed."
                ).arg(scanCacheFilePath()));
            // The run's own script is an executable holding the very rm lines
            // it just carried out, under a temp name the user has no way to
            // guess. If its removal did not land it is named here, while there
            // is still a window to name it in.
            QString scriptWarn;
            if (!m_script->scriptLeftBehind().isEmpty()) {
                scriptWarn = redactHomePaths(QStringLiteral(
                    "The generated script at %1 could not be removed. Nothing runs it by itself, "
                    "but it holds the delete commands from this run, so you can delete it."
                ).arg(m_script->scriptLeftBehind()));
            }
            if (stopped || code != 0) {
                QString err = redactHomePaths(QString::fromUtf8(output).trimmed());
                if (err.size() > 400) {
                    err = err.right(400);
                    // QString::right counts UTF-16 units, so the cut can land
                    // between the halves of an astral character and the banner
                    // shows a replacement character. Same hazard the byte-level
                    // cut in ScriptProcess guards against, one level up.
                    int drop = 0;
                    while (drop < err.size() && err.at(drop).isLowSurrogate()) ++drop;
                    if (drop > 0) err.remove(0, drop);
                }
                if (stopped) {
                    /* The exit status says SIGTERM or SIGKILL, which describes
                       how the stop was carried out and not what went wrong. The
                       reason is the deadline, and what it cost is the lines that
                       already ran. */
                    const QString head = QStringLiteral(
                        "The script was stopped after %1 minutes without finishing. "
                        "Commands before the stop may have already run."
                    ).arg(localeCount(kScriptTimeoutMinutes));
                    err = err.isEmpty() ? head : head + QStringLiteral("\n") + err;
                } else if (err.isEmpty()) {
                    err = QStringLiteral(
                        "The script failed (exit %1). Commands before the failure may have already run."
                    ).arg(localeCount(code));
                } else {
                    err = QStringLiteral(
                        "The script failed (exit %1). Commands before the failure may have already run.\n%2"
                    ).arg(localeCount(code)).arg(err);
                }
                for (const QString &warn : {cacheWarn, scriptWarn}) {
                    if (warn.isEmpty()) continue;
                    err = err.isEmpty() ? warn : err + QStringLiteral("\n") + warn;
                }
                showError(err);
                if (stopped) statusBar()->showMessage(QStringLiteral("Script stopped."));
                refreshActionBar();
                if (m_table->isVisible()) rebuildInspector();
            } else {
                /* A successful run clears the error bar, and a removal that did
                   not land is one the user has to act on, so it goes back up
                   after the clear rather than being lost with it. */
                if (!cacheWarn.isEmpty() || !scriptWarn.isEmpty()) {
                    showError(cacheWarn.isEmpty()
                        ? scriptWarn
                        : cacheWarn + QStringLiteral("\n") + scriptWarn);
                } else if (!m_settingsError) {
                    m_errorBar->hide();
                    m_error->clear();
                }
                // "Finished" named no action and no count, so a run that
                // removed an app the user expected to keep read the same as
                // one that removed nothing they had looked at. The rows
                // vanishing was the only signal the script had run.
                statusBar()->showMessage(done);
                m_marked.clear();
                m_markedManual.clear();
                rescan();
            }
            retireScript();
        });
        m_script->start();
    }

    void applySystemAppearance() {
        if (!m_table || m_applyingAppearance) return;
        m_applyingAppearance = true;
        // A light/dark switch hands back a new palette, which carries the
        // theme's own placeholder colour again. The floor goes on with it.
        QApplication::setPalette(aaPaletteWithReadablePlaceholder(QApplication::palette()));
        resetWidgetPalette(m_table);
        resetWidgetPalette(m_inspectorHost);
        resetWidgetPalette(m_inspectorScroll);
        resetWidgetPalette(m_emptyPane);
        resetWidgetPalette(m_emptyTitle);
        resetWidgetPalette(m_emptyDetail);
        resetWidgetPalette(m_ovLeftovers);
        resetWidgetPalette(m_ovStale);
        resetWidgetPalette(m_ovOutdated);
        if (m_sidebar) aaApplySourceList(m_sidebar);
        if (m_settingsNav) aaApplySourceList(m_settingsNav);
        m_applyingAppearance = false;
    }

    void changeEvent(QEvent *e) override {
        QMainWindow::changeEvent(e);
        if (!e) return;
        if (e->type() == QEvent::PaletteChange || e->type() == QEvent::ApplicationPaletteChange
            || e->type() == QEvent::StyleChange) {
            applySystemAppearance();
            if (m_table) fillCurrent();
        }
    }

    void applyLoadedSettings(const AppSettings &s) {
        m_confirmDelete = s.confirmDelete;
        m_includeSystemOn = s.includeSystem;
        m_ignored.clear();
        for (const QString &p : s.ignoredLeftoverPaths) {
            if (!p.isEmpty()) m_ignored.insert(pathIdentityKey(p));
        }
        {
            const QSignalBlocker b1(m_confirmBox);
            m_confirmBox->setChecked(m_confirmDelete);
        }
        refreshIgnoredList();
    }

    void loadSettings() {
        m_settingsError = false;
        const QString path = settingsFilePath();
        QFile f(path);
        if (!f.exists()) {
            bool hadLegacy = false;
            QStringList unreadable;
            QString legacyPath;
            const AppSettings s = migrateLegacyQSettings(&hadLegacy, &unreadable, &legacyPath);
            if (!unreadable.isEmpty()) {
                // Migrating would write the defaults over a value the user
                // wrote, so stop here and name the key instead. Only editing
                // the legacy file clears this: persistSettings returns while
                // the error is held, so saving settings is not the way out.
                m_settingsError = true;
                showError(settingsLegacyMessage(unreadable, legacyPath));
                return;
            }
            applyLoadedSettings(s);
            if (hadLegacy && persistSettings()) {
                // The values are in settings.json, which is owner-only, so the
                // old file is a second copy of the account's own paths under a
                // name nothing reads any more. Delete it here rather than
                // leaving it for the user to find: a migration that did not
                // reach disk keeps it, because then it is the only copy.
                //
                // A removal that did not land is reported: the file was
                // written by QSettings at the umask default and holds the
                // account's own ignore-list paths, so a copy that survived is
                // a second set of paths on disk under a name nothing reads
                // again. `migrateLegacyQSettings` has already narrowed its
                // mode, so this is a file the user can delete by hand.
                if (!removeLegacySettingsFile(legacyPath) && QFile::exists(legacyPath)) {
                    showError(redactHomePaths(QStringLiteral(
                        "The old settings file at %1 could not be removed. Nothing reads it any more, "
                        "but it still holds your ignored-leftovers paths and you can delete it."
                    ).arg(legacyPath)));
                }
            }
            return;
        }
        if (!f.open(QIODevice::ReadOnly)) {
            m_settingsError = true;
            showError(settingsUnreadableMessage(path));
            return;
        }
        const QByteArray raw = f.readAll();
        AppSettings s;
        QString err;
        if (!parseSettingsJson(raw, &s, &err)) {
            m_settingsError = true;
            showError(settingsInvalidMessage(path, err));
            return;
        }
        applyLoadedSettings(s);
    }

    /// Put the settings backup back and carry on as a normal load. The
    /// restore checks the backup parses with this window's own loader before
    /// it writes anything, keeps the file it replaces, and says why it did
    /// not, so the button cannot be the step that loses the ignore list.
    void restoreSettingsFromBackup() {
        const QString path = settingsFilePath();
        QString err;
        if (!restoreSettingsBackup(path, &err)) {
            refreshRestoreButton();
            showError(redactHomePaths(err));
            return;
        }
        loadSettings();
        refreshIgnoredList();
        fillCurrent();
        refreshRestoreButton();
        const QString restored = QStringLiteral(
            "Settings restored from the backup. The file it replaced is "
            "settings.json.bad if you need it."
        );
        statusBar()->showMessage(restored);
        aaAnnounce(m_stack, restored);
    }

    /// The button is disabled rather than failing on click when there is
    /// nothing to restore, because a machine with no backup cannot use it.
    void refreshRestoreButton() {
        if (!m_restoreSettings) return;
        const bool there = QFile::exists(settingsBackupPath(settingsFilePath()));
        m_restoreSettings->setEnabled(there);
        m_restoreSettings->setToolTip(
            there ? QStringLiteral(
                        "Put settings.json.bak back in place of the settings file, and keep "
                        "the file being replaced as settings.json.bad")
                  : QStringLiteral("There is no settings backup to restore.")
        );
    }

    /// True when the settings reached disk. The migration needs the answer:
    /// it deletes the legacy file only after the copy that replaced it is
    /// written, so a failed write leaves the old file as the only copy of the
    /// account's paths.
    bool persistSettings() {
        if (m_settingsError) return false;
        AppSettings s;
        s.confirmDelete = m_confirmDelete;
        s.includeSystem = m_includeSystemOn;
        s.ignoredLeftoverPaths = QStringList(m_ignored.begin(), m_ignored.end());
        const QString path = settingsFilePath();
        const QFileInfo fi(path);
        if (!QDir().mkpath(fi.absolutePath())) {
            showError(settingsUnwritableMessage(path));
            return false;
        }
        /* Narrow the parent before the file lands in it, not after: mkpath
           creates at the umask default (0755), so an owner-only settings file
           sat in a world-readable directory for as long as the run took. The
           Swift scanner's prepareStateDirectory does this in the same order. */
        if (QFileInfo(fi.absolutePath()).fileName().compare(QStringLiteral("appattic"), Qt::CaseInsensitive) == 0) {
            restrictOwnerOnlyDir(fi.absolutePath());
        }
        /* Keep the file being replaced as settings.json.bak first. The ignore
           list is the user's own choices and a scan cannot rebuild it, so the
           state before this write has to outlive it. A backup that does not
           land is not a reason to refuse the save the user asked for. */
        keepSettingsBackup(path);
        if (!writeDurableFile(encodeSettingsJson(s), path)) {
            showError(settingsUnwritableMessage(path));
            return false;
        }
        restrictPrivateDataFile(path);
        m_settingsError = false;
        m_errorBar->hide();
        m_error->clear();
        refreshIgnoredList();
        return true;
    }

    /// One hidden path back in the list. The double click and the Show Again
    /// button both land here, so the two ways in say the same thing and do the
    /// same work.
    void restoreIgnoredLeftover(const QString &key, const QString &label) {
        if (key.isEmpty() || !m_ignored.remove(key)) return;
        persistSettings();
        fillCurrent();
        const QString shown = QStringLiteral("Shown in the list again: %1.").arg(label);
        statusBar()->showMessage(shown);
        // The list the path left is on another page, so the status bar is the
        // only place the result is written, and it is not announced on its own.
        aaAnnounce(m_ignoredList, shown);
    }

    void refreshIgnoredList() {
        if (!m_ignoredList) return;
        m_ignoredList->clear();
        if (m_showIgnored) m_showIgnored->setEnabled(false);
        m_ignoredEmpty->setVisible(m_ignored.isEmpty());
        m_ignoredList->setVisible(!m_ignored.isEmpty());
        if (m_ignored.isEmpty()) {
            m_clearIgnored->setEnabled(false);
            return;
        }
        // Collation, not code points: `QStringList::sort()` puts "Zebra" before
        // "apple" and "Ä" after "Z", so a German or Swedish reader sees an
        // unordered list. The C locale has no collation rules and keeps the
        // code-point order.
        QList<QPair<QString, QString>> entries; // label, hidden key
        for (const QString &p : m_ignored) entries.append({ignoredPathLabel(p), p});
        const QLocale locale;
        if (locale.name() == QLatin1String("C")) {
            std::sort(entries.begin(), entries.end(), [](const auto &a, const auto &b) {
                return a.first < b.first;
            });
        } else {
            // QCollator, not QLocale: only the collator is callable, and it
            // holds the locale's collation rules.
            const QCollator collator(locale);
            std::sort(entries.begin(), entries.end(), [&collator](const auto &a, const auto &b) {
                return collator.compare(a.first, b.first) < 0;
            });
        }
        for (const auto &e : entries) {
            auto *it = new QListWidgetItem(e.first, m_ignoredList);
            it->setData(Qt::UserRole, e.second);
            it->setToolTip(plainTooltip(e.second));
        }
        m_ignoredList->setToolTip(
            localeCount(m_ignored.size())
            + QStringLiteral(" hidden. Select a path, then press Show Again, to show that leftover in the list.")
        );
        m_clearIgnored->setEnabled(true);
    }

    QListWidget *m_sidebar = nullptr;
    QListWidget *m_settingsNav = nullptr;
    QLabel *m_pageTitle = nullptr;
    QStackedWidget *m_stack = nullptr;
    DiskPage *m_diskPage = nullptr;
    QTreeView *m_table = nullptr;
    /// Rows are handed to the model, which paints them on demand; a fill is a
    /// vector swap, not one heap item per row.
    FindingModel *m_model = nullptr;
    QWidget *m_emptyPane = nullptr;
    QLabel *m_emptyTitle = nullptr;
    QLabel *m_emptyDetail = nullptr;
    QPushButton *m_clearSearch = nullptr;
    QPushButton *m_emptyRetry = nullptr;
    QWidget *m_errorBar = nullptr;
    QScrollArea *m_inspectorScroll = nullptr;
    QWidget *m_inspectorHost = nullptr;
    QVBoxLayout *m_inspectorLay = nullptr;
    QVector<QLabel *> m_factKeys;
    QLabel *m_count = nullptr;
    QProgressBar *m_scanBar = nullptr;
    QAction *m_countAct = nullptr;
    QAction *m_scanBarAct = nullptr;
    QAction *m_searchAct = nullptr;
    QAction *m_filterAct = nullptr;
    QAction *m_selectAllAct = nullptr;
    QAction *m_rescanAct = nullptr;
    QLabel *m_error = nullptr;
    QLineEdit *m_search = nullptr;
    QTimer *m_searchDebounce = nullptr;
    QComboBox *m_filter = nullptr;
    QPushButton *m_selectAll = nullptr;
    QPushButton *m_rescan = nullptr;
    QWidget *m_actionBar = nullptr;
    QLabel *m_actionCount = nullptr;
    QLabel *m_actionBytes = nullptr;
    QPushButton *m_clearSel = nullptr;
    QPushButton *m_preview = nullptr;
    QPushButton *m_deleteBtn = nullptr;
    QPushButton *m_updateBtn = nullptr;
    QPushButton *m_markManualBtn = nullptr;
    QCheckBox *m_confirmBox = nullptr;
    QListWidget *m_ignoredList = nullptr;
    QLabel *m_ignoredEmpty = nullptr;
    QPushButton *m_clearIgnored = nullptr;
    QPushButton *m_showIgnored = nullptr;
    // Put the settings backup back, for the machine whose settings file does not
    // read: the list it holds is the user's own paths and nothing rebuilds them.
    QPushButton *m_restoreSettings = nullptr;
    QLabel *m_statInstalled = nullptr;
    QLabel *m_statLeftovers = nullptr;
    QLabel *m_statLeftoverData = nullptr;
    QLabel *m_statStale = nullptr;
    QLabel *m_statOutdated = nullptr;
    QLabel *m_statPackages = nullptr;
    QLabel *m_statScan = nullptr;
    QTreeWidget *m_ovLeftovers = nullptr;
    QTreeWidget *m_ovStale = nullptr;
    QTreeWidget *m_ovOutdated = nullptr;
    QLabel *m_ovLeftEmpty = nullptr;
    QLabel *m_ovStaleEmpty = nullptr;
    QLabel *m_ovOutEmpty = nullptr;
    QThread *m_scanThread = nullptr;
    ScanWorker *m_worker = nullptr;
    ScriptProcess *m_script = nullptr;
    QVector<Finding> m_findings;
#ifndef NDEBUG
    QString m_shotDir;
    QVector<QPair<Page, QString>> m_shotQueue;
    int m_shotIndex = 0;
    int m_shotExit = 0;
    int m_shotPages = 0;
    /// Streaming gate bookkeeping: how many times rows arrived, and which of
    /// them the final list still has.
    int m_partialSeen = 0;
    int m_partialRowsFirst = -1;
    QSet<QString> m_partialUids;
#endif
    QSet<QString> m_marked;
    QSet<QString> m_markedManual;
    QSet<QString> m_ignored;
    QString m_selectedUid;
    QString m_selectedChild;
    int m_scanGen = 0;
    QString m_scanAt;
    QString m_scanPhase;
    int m_scanIndex = 0;
    int m_scanTotal = 0;
    bool m_scanning = false;
    bool m_hasScanned = false;
    bool m_scanOk = false;
    bool m_confirmDelete = true;
    bool m_includeSystemOn = false;
    bool m_applyingAppearance = false;
    bool m_settingsError = false;
};

#ifndef NDEBUG
static const char *argvValue(int argc, char **argv, const char *flag) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::strcmp(argv[i], flag) == 0) return argv[i + 1];
    }
    return nullptr;
}
#endif

static bool argvHas(int argc, char **argv, const char *flag) {
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], flag) == 0) return true;
    }
    return false;
}

/* A misspelled long option used to fall through to the window: `appattic-qt
   --smok` opened a GUI and ran no check, which a script reads as a hang. Qt's
   own options are single-dash (-platform, -style, -widgetcount, ...), so a
   double-dash token is this binary's own and has to be named or exit 2. The
   release build already rejects --dev-check the same way. */
static int rejectUnknownOptions(int argc, char **argv) {
    for (int i = 1; i < argc; ++i) {
        const char *a = argv[i];
        if (std::strcmp(a, "--help") == 0 || std::strcmp(a, "--version") == 0
            || std::strcmp(a, "--smoke") == 0) {
            continue;
        }
        if (std::strcmp(a, "--dev-check") == 0) {
            ++i; /* the check name, and the optional shot dir, are not options */
            continue;
        }
        if (a[0] == '-' && a[1] == '-' && a[2] != '\0') {
            std::fprintf(stderr, "error: unknown option: %s\n", a);
            std::fprintf(stderr, "Try 'appattic-qt --help' for more information.\n");
            return 2;
        }
    }
    return 0;
}

static int runHelp() {
    /* The dev-only gates are listed only in a build that has them, so a
       release user is not sent to a flag the binary compiled out. */
    std::string usage = "usage: appattic-qt [--version] [--help] [--smoke]";
    std::string options =
        "  --version   print version and exit\n"
        "  --help, -h  print this help and exit\n"
        "  --smoke     headless smoke test and exit\n";
#ifndef NDEBUG
    usage += " [--dev-check <check>]";
    options +=
        "  --dev-check <table|stream|disk|overview|shot> [dir]\n"
        "              debug build only: run one check and exit\n";
#endif
    std::fprintf(stdout, "%s\n\n%s", usage.c_str(), options.c_str());
    return 0;
}

static int smokeUiCopy() {
    if (pageSearchEmpty(Page::Leftovers)
        != QLatin1String("No leftovers match this search.")) {
        std::fprintf(stderr, "ui-copy: leftovers search empty\n");
        return 1;
    }
    if (pageEmptyTitle(Page::Leftovers, true, false) != QLatin1String("Scanning")) {
        std::fprintf(stderr, "ui-copy: scanning title\n");
        return 1;
    }
    if (pageEmptyTitle(Page::Stale, false, true) != QLatin1String("Scan failed")) {
        std::fprintf(stderr, "ui-copy: scan failed title\n");
        return 1;
    }
    const QString stale = pageEmptyDetail(
        Page::Stale, false, false, QString(), 0, QString(), QString()
    );
    if (stale.contains(QLatin1String("WASM")) || stale.contains(QLatin1String("plugin ships"))) {
        std::fprintf(stderr, "ui-copy: stale empty still mentions internals\n");
        return 1;
    }
    const QString scanning = pageEmptyDetail(
        Page::Leftovers, true, false, QString(), 0, QString(), QString()
    );
    if (!scanning.contains(QLatin1String("Looking for leftover data"))) {
        std::fprintf(stderr, "ui-copy: scanning detail\n");
        return 1;
    }
    const QString pkg = pageEmptyDetail(
        Page::Packages, false, false, QString(), 0, QStringLiteral("all"), QString()
    );
    if (pkg.contains(QLatin1String("this page stays"))) {
        std::fprintf(stderr, "ui-copy: packages empty still uses internal phrasing\n");
        return 1;
    }
    const QString readMsg = settingsUnreadableMessage(QStringLiteral("/tmp/settings.json"));
    if (readMsg.contains(QLatin1String("cannot read settings"))
        || !readMsg.contains(QLatin1String("Could not read settings"))) {
        std::fprintf(stderr, "ui-copy: settings read still uses developer phrasing\n");
        return 1;
    }
    const QString badMsg = settingsInvalidMessage(
        QStringLiteral("/tmp/settings.json"), QStringLiteral("not valid JSON")
    );
    if (badMsg.contains(QLatin1String("invalid settings /tmp"))
        || !badMsg.contains(QLatin1String("not valid JSON"))) {
        std::fprintf(stderr, "ui-copy: settings invalid still uses developer phrasing\n");
        return 1;
    }
    /* The ignore list is the user's own paths and no scan rebuilds it, so a
       settings file that will not read leaves settings.json.bak as the only
       other copy. Both messages name that path: a user told the file is bad
       and nothing else is on the machine a runbook they have not opened away. */
    if (!readMsg.contains(QLatin1String("/tmp/settings.json.bak"))
        || !badMsg.contains(QLatin1String("/tmp/settings.json.bak"))) {
        std::fprintf(stderr, "ui-copy: settings error does not name the backup to restore from\n");
        return 1;
    }
    const QString legacyMsg = settingsLegacyMessage(
        {QStringLiteral("includeSystem")}, QStringLiteral("/tmp/AppAttic.conf")
    );
    // The phrase checked here is the message's own wording. It read "true nor
    // false" until the message was rewritten to "so they read true or false",
    // which left the check unsatisfiable and made every --smoke run fail after
    // the scan it had already passed.
    if (!legacyMsg.contains(QLatin1String("includeSystem"))
        || !legacyMsg.contains(QLatin1String("read true or false"))
        || !legacyMsg.contains(QLatin1String("/tmp/AppAttic.conf"))) {
        std::fprintf(stderr, "ui-copy: settings legacy message does not name the key and the old file\n");
        return 1;
    }
    if (ignoredPathLabel(QStringLiteral("/tmp/Caches/Foo")) != QLatin1String("Caches/Foo")) {
        std::fprintf(stderr, "ui-copy: ignored path label\n");
        return 1;
    }
    std::fprintf(stdout, "ui-copy: ok\n");
    return 0;
}

static QIcon loadAppIcon() {
    QIcon embedded(QStringLiteral(":/icons/appattic.png"));
    if (!embedded.isNull()) return embedded;
    QIcon themed = QIcon::fromTheme(QStringLiteral("appattic"));
    if (themed.isNull()) {
        themed = QIcon::fromTheme(QStringLiteral("org.appattic.AppAttic"));
    }
    if (!themed.isNull()) return themed;
    const QDir exeDir(QCoreApplication::applicationDirPath());
    const QStringList candidates = {
        exeDir.absoluteFilePath(QStringLiteral("../share/icons/hicolor/128x128/apps/appattic.png")),
        exeDir.absoluteFilePath(QStringLiteral("../share/icons/hicolor/scalable/apps/appattic.svg")),
        exeDir.absoluteFilePath(QStringLiteral("../share/icons/hicolor/scalable/apps/org.appattic.AppAttic.svg")),
        exeDir.absoluteFilePath(QStringLiteral("../../../packaging/appattic.png")),
        exeDir.absoluteFilePath(QStringLiteral("../../../packaging/appattic.svg")),
    };
    for (const QString &p : candidates) {
        if (QFileInfo::exists(p)) return QIcon(p);
    }
    return {};
}

static void applyAppIdentity() {
    QApplication::setApplicationName(QStringLiteral("AppAttic"));
    QApplication::setApplicationDisplayName(QStringLiteral("AppAttic"));
    QApplication::setOrganizationName(QStringLiteral("AppAttic"));
    // The desktop entry every format installs is named after the app id, and
    // Qt publishes this as GTK_APPLICATION_ID and KDE_NET_WM_DESKTOP_FILE, so
    // the panel groups the window and the Wayland compositor looks up its
    // header icon by this name. Any other name, sandboxed or not, points at a
    // desktop file nothing installs.
    QGuiApplication::setDesktopFileName(QStringLiteral("org.appattic.AppAttic"));
    const QIcon icon = loadAppIcon();
    if (!icon.isNull()) QApplication::setWindowIcon(icon);
    if (QIcon::themeName().isEmpty()) {
        QIcon::setThemeName(QStringLiteral("breeze"));
    }
    aaLoadAppFonts();
    // Every widget reads its colours from the application palette, so the
    // placeholder-text contrast floor is set here, once, rather than on each
    // of the labels that use the role.
    QApplication::setPalette(aaPaletteWithReadablePlaceholder(QApplication::palette()));
}

int main(int argc, char **argv) {
    if (argvHas(argc, argv, "--help") || argvHas(argc, argv, "-h")) {
        return runHelp();
    }
    if (argvHas(argc, argv, "--version")) {
        return runVersion(argc, argv);
    }
    if (const int rc = rejectUnknownOptions(argc, argv); rc != 0) return rc;
#ifndef NDEBUG
    /* Dev-only gates: table model, streaming rows, disk streaming, renders.
       Release ships only --smoke, which the AppImage step self-checks with. */
    if (const char *which = argvValue(argc, argv, "--dev-check")) {
        /* The name is checked before QApplication and the window exist: a typo
           has to read as a usage error with exit 2, the same as the release
           build's rejection of the flag itself, rather than the app opening and
           then complaining. */
        if (std::strcmp(which, "table") != 0 && std::strcmp(which, "stream") != 0
            && std::strcmp(which, "disk") != 0 && std::strcmp(which, "shot") != 0
            && std::strcmp(which, "overview") != 0) {
            std::fprintf(stderr, "error: unknown check: %s\n", which);
            std::fprintf(stderr, "usage: --dev-check <table|stream|disk|overview|shot> [dir]\n");
            std::fprintf(stderr, "Try 'appattic-qt --help' for more information.\n");
            return 2;
        }
        if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")
            && qEnvironmentVariableIsEmpty("DISPLAY")
            && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY")) {
            qputenv("QT_QPA_PLATFORM", "offscreen");
        }
        QApplication app(argc, argv);
        QApplication::setApplicationName(QStringLiteral("AppAttic"));
        applyAppIdentity();
        MainWindow w;
        w.resize(1400, 900);
        w.show();
        const QLatin1String name(which);
        if (name == QLatin1String("table")) return w.smokeTableChecks();
        if (name == QLatin1String("overview")) return w.smokeOverviewChecks();
        if (name == QLatin1String("stream")) return w.smokeStreamChecks();
        if (name == QLatin1String("disk")) return w.smokeDiskStreamChecks();
        if (name == QLatin1String("shot")) {
            const char *dir = nullptr;
            for (int i = 1; i + 2 < argc; ++i) {
                if (std::strcmp(argv[i], "--dev-check") == 0) dir = argv[i + 2];
            }
            // Relative default: the shots are build output, so they land beside
            // the binary that took them and not on a tmpfs that discards them.
            w.startShots(dir ? QString::fromUtf8(dir) : QStringLiteral("shots"));
            return app.exec();
        }
        /* The name was checked before the window existed, so reaching here
           means a name was added to that check without a branch: fail, rather
           than open the window and run nothing. */
        std::fprintf(stderr, "error: --dev-check %s is not wired to a check\n", which);
        return 2;
    }
#else
    /* The dev gates are compiled out here, so the flag has to fail instead of
       falling through to the window: `--dev-check table` on a release binary
       would open the app and run no check, which reads as a hung command.
       --smoke is the headless gate that ships. */
    if (argvHas(argc, argv, "--dev-check")) {
        std::fprintf(stderr, "error: --dev-check is a debug-build gate; this is a release build\n");
        std::fprintf(stderr, "       --smoke is the headless check that ships\n");
        std::fprintf(stderr, "Try 'appattic-qt --help' for more information.\n");
        return 2;
    }
#endif
    if (argvHas(argc, argv, "--smoke")) {
        /* Date parsing and disk usage checks run in appattic-qt-helper-tests;
           this gate proves the linked binary scans. */
        const int rc = runSmoke(argc, argv);
        if (rc != 0) return rc;
        return smokeUiCopy();
    }
    QApplication app(argc, argv);
    qRegisterMetaType<QVector<Finding>>();
    applyAppIdentity();
    MainWindow w;
    if (!QApplication::windowIcon().isNull()) w.setWindowIcon(QApplication::windowIcon());
    w.show();
    return app.exec();
}

#include "main.moc"
