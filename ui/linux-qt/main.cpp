#include "corehost.h"
#include "finding.h"
#include "settings.h"
#include "smoke.h"

#include <QAbstractItemView>
#include <QAction>
#include <QApplication>
#include <QByteArray>
#include <QCheckBox>
#include <QClipboard>
#include <QColor>
#include <QComboBox>
#include <QCoreApplication>
#include <QDate>
#include <QDateTime>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QFontMetrics>
#include <QFrame>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QIODevice>
#include <QKeySequence>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QListWidgetItem>
#include <QMainWindow>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QModelIndex>
#include <QObject>
#include <QPainter>
#include <QPalette>
#include <QPlainTextEdit>
#include <QProcess>
#include <QPushButton>
#include <QRect>
#include <QSaveFile>
#include <QScrollArea>
#include <QSet>
#include <QSignalBlocker>
#include <QSize>
#include <QSplitter>
#include <QStackedWidget>
#include <QStatusBar>
#include <QStyle>
#include <QStyleHints>
#include <QStyleOptionViewItem>
#include <QStyledItemDelegate>
#include <QTemporaryFile>
#include <QThread>
#include <QTimer>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QUrl>
#include <QVariant>
#include <QVBoxLayout>
#include <QVector>
#include <QWidget>

#include <cstdio>
#include <cstring>
#include <limits>
#include <utility>

static void resetWidgetPalette(QWidget *w) {
    if (!w) return;
    w->setAttribute(Qt::WA_SetPalette, false);
    w->setPalette(QApplication::palette());
}

static qint64 addBytes(qint64 a, qint64 b) {
    if (b <= 0) return a;
    if (a > std::numeric_limits<qint64>::max() - b) return std::numeric_limits<qint64>::max();
    return a + b;
}

static bool isDarkPalette(const QPalette &p) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    const Qt::ColorScheme scheme = QGuiApplication::styleHints()->colorScheme();
    if (scheme == Qt::ColorScheme::Dark) return true;
    if (scheme == Qt::ColorScheme::Light) return false;
#endif
    return p.color(QPalette::Window).lightness() < 128;
}

static QFont bodyFont() {
    return QApplication::font();
}

static QFont smallFont() {
    QFont f = QApplication::font();
    const int ps = f.pointSize();
    if (ps > 0) f.setPointSize(qMax(9, ps - 2));
    else if (f.pixelSize() > 0) f.setPixelSize(qMax(11, f.pixelSize() - 2));
    return f;
}

static int rowPx() {
    return QFontMetrics(bodyFont()).height() + 6;
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
                    : QString::number(ignoredCount) + QStringLiteral(" leftover paths hidden from the list."));
        }
        return body;
    }
    case Page::Stale:
        return QStringLiteral("No unused installed apps in this scan.");
    case Page::Outdated:
        return QStringLiteral(
            "No outdated packages. Brew, Flatpak, Snap, apt, pacman, dnf, zypper, and the App Store reported nothing, or those tools are not installed."
        );
    case Page::Packages:
        if (packageFilter == QLatin1String("globals")) {
            return QStringLiteral("No user-global npm, pnpm, bun, pipx, or uv tools.");
        }
        if (packageFilter == QLatin1String("leaves")) {
            return QStringLiteral(
                "No distro orphans. apt/pacman/dnf/zypper reported nothing, or those tools are not installed."
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
    if (f.currentVersion.isEmpty() && f.latestVersion.isEmpty()) return QStringLiteral("-");
    return (f.currentVersion.isEmpty() ? QStringLiteral("-") : f.currentVersion)
        + QStringLiteral(" → ")
        + (f.latestVersion.isEmpty() ? QStringLiteral("?") : f.latestVersion);
}

static QString scanSummaryMessage(int leftovers, int stale, int outdated, int packages, const QString &when) {
    return QStringLiteral("Scanned %1 · %2 leftovers, %3 stale, %4 outdated, %5 packages")
        .arg(when.isEmpty() ? QStringLiteral("now") : when)
        .arg(leftovers)
        .arg(stale)
        .arg(outdated)
        .arg(packages);
}

static QString settingsUnreadableMessage(const QString &path) {
    return QStringLiteral(
        "Could not read settings at %1. AppAttic will not overwrite that file until you save settings."
    ).arg(path);
}

static QString settingsInvalidMessage(const QString &path, const QString &err) {
    return QStringLiteral(
        "Settings at %1 are not valid (%2). AppAttic will not overwrite that file until you save settings."
    ).arg(path, err);
}

static QString settingsUnwritableMessage(const QString &path) {
    return QStringLiteral("Could not save settings to %1.").arg(path);
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
    t.green = dark ? QColor(48, 209, 88) : QColor(36, 138, 61);
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

class ScanWorker : public QObject {
    Q_OBJECT
public slots:
    void run(const QString &core, const QStringList &pluginSpecs) {
        QByteArray blobs;
        char err[1024];
        err[0] = '\0';
        const int rc = collectCoreWasm(core, pluginSpecs, &blobs, err, sizeof err);
        emit finished(blobs, QString::fromUtf8(err), rc);
    }
signals:
    void finished(const QByteArray &blobs, const QString &err, int rc);
};

class SidebarDelegate : public QStyledItemDelegate {
public:
    explicit SidebarDelegate(QObject *parent = nullptr) : QStyledItemDelegate(parent) {}

    void paint(QPainter *p, const QStyleOptionViewItem &opt, const QModelIndex &idx) const override {
        QStyleOptionViewItem o = opt;
        initStyleOption(&o, idx);
        const QWidget *w = o.widget;
        QStyle *style = w ? w->style() : QApplication::style();
        style->drawPrimitive(QStyle::PE_PanelItemViewItem, &o, p, w);

        const QString name = idx.data(Qt::DisplayRole).toString();
        const int count = idx.data(Qt::UserRole).toInt();
        QFont body = bodyFont();
        QFont small = smallFont();
        const QColor fg = o.palette.color(
            o.state & QStyle::State_Selected ? QPalette::HighlightedText : QPalette::Text
        );
        QColor dim = fg;
        if (!(o.state & QStyle::State_Selected)) {
            dim = toneFrom(o.palette).dim;
        } else {
            dim.setAlpha(230);
        }
        p->setPen(fg);
        p->setFont(body);
        QRect nameR = o.rect.adjusted(10, 0, -10, 0);
        QString countText;
        if (count > 0) {
            countText = QString::number(count);
            p->setFont(small);
            const int cw = p->fontMetrics().horizontalAdvance(countText) + 4;
            nameR.setRight(nameR.right() - cw);
            p->setPen(dim);
            p->drawText(
                QRect(nameR.right(), o.rect.top(), cw, o.rect.height()),
                Qt::AlignVCenter | Qt::AlignRight,
                countText
            );
            p->setPen(fg);
            p->setFont(body);
        }
        p->drawText(nameR, Qt::AlignVCenter | Qt::AlignLeft, name);
    }

    QSize sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &) const override {
        return QSize(opt.rect.width(), rowPx());
    }
};

class TableRowDelegate : public QStyledItemDelegate {
public:
    explicit TableRowDelegate(QObject *parent = nullptr) : QStyledItemDelegate(parent) {}

    void initStyleOption(QStyleOptionViewItem *option, const QModelIndex &index) const override {
        QStyledItemDelegate::initStyleOption(option, index);
        if (option->state & QStyle::State_Selected) {
            const QColor onAccent = option->palette.color(QPalette::HighlightedText);
            option->palette.setColor(QPalette::Text, onAccent);
            option->palette.setColor(QPalette::WindowText, onAccent);
            option->palette.setBrush(QPalette::Text, onAccent);
            option->palette.setBrush(QPalette::WindowText, onAccent);
        }
    }

    QSize sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &index) const override {
        QSize s = QStyledItemDelegate::sizeHint(opt, index);
        s.setHeight(rowPx());
        return s;
    }
};

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    explicit MainWindow() {
        setWindowTitle(QStringLiteral("AppAttic"));
        resize(1180, 720);
        setMinimumSize(800, 520);
        QFont body = bodyFont();
        setFont(body);

        m_scanThread = new QThread(this);
        m_worker = new ScanWorker;
        m_worker->moveToThread(m_scanThread);
        m_scanThread->start();
        connect(this, &MainWindow::requestScan, m_worker, &ScanWorker::run);
        connect(m_worker, &ScanWorker::finished, this, &MainWindow::scanFinished);

        auto *outer = new QSplitter(Qt::Horizontal, this);
        outer->setChildrenCollapsible(false);

        m_sidebar = new QListWidget;
        m_sidebar->setFixedWidth(220);
        m_sidebar->setFrameShape(QFrame::NoFrame);
        m_sidebar->setContentsMargins(8, 8, 8, 8);
        m_sidebar->setItemDelegate(new SidebarDelegate(m_sidebar));
        m_sidebar->setSpacing(2);
        m_sidebar->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        const QStringList pages = {
            QStringLiteral("Overview"),
            QStringLiteral("Leftovers"),
            QStringLiteral("Stale Apps"),
            QStringLiteral("Outdated"),
            QStringLiteral("Packages"),
            QStringLiteral("Settings"),
        };
        for (const QString &p : pages) {
            auto *it = new QListWidgetItem(p);
            it->setData(Qt::UserRole, 0);
            m_sidebar->addItem(it);
        }
        m_sidebar->setCurrentRow(0);

        auto *right = new QWidget;
        auto *rv = new QVBoxLayout(right);
        rv->setContentsMargins(0, 0, 0, 0);
        rv->setSpacing(0);

        auto *tools = new QWidget;
        tools->setAutoFillBackground(true);
        {
            QPalette tp = tools->palette();
            tp.setColor(QPalette::Window, tp.color(QPalette::Button));
            tools->setPalette(tp);
        }
        auto *th = new QHBoxLayout(tools);
        th->setContentsMargins(16, 8, 16, 8);
        th->setSpacing(8);
        m_count = new QLabel;
        QFont small = smallFont();
        m_count->setFont(small);
        m_count->setForegroundRole(QPalette::PlaceholderText);
        m_search = new QLineEdit;
        m_search->setPlaceholderText(QStringLiteral("Search"));
        m_search->setClearButtonEnabled(true);
        m_search->setFixedWidth(200);
        m_search->setFont(body);
        m_search->setToolTip(QStringLiteral("Filter the current list by name, path, or kind"));
        m_filter = new QComboBox;
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
        m_filter->setFont(small);
        m_selectAll = new QPushButton(QStringLiteral("Select All"));
        m_selectAll->setToolTip(
            QStringLiteral("Include every visible item in cleanup, update, or remove")
        );
        m_rescan = new QPushButton(QStringLiteral("Rescan"));
        th->addWidget(m_count);
        th->addStretch();
        th->addWidget(m_search);
        th->addWidget(m_filter);
        th->addWidget(m_selectAll);
        th->addWidget(m_rescan);

        auto *toolsRule = new QFrame;
        toolsRule->setFrameShape(QFrame::HLine);
        toolsRule->setFrameShadow(QFrame::Plain);

        m_errorBar = new QWidget;
        auto *eh = new QHBoxLayout(m_errorBar);
        eh->setContentsMargins(16, 8, 16, 8);
        eh->setSpacing(8);
        m_error = new QLabel;
        m_error->setFont(body);
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

        m_overview = buildOverview();
        m_stack->addWidget(m_overview);

        auto *listPage = new QWidget;
        auto *listSplit = new QSplitter(Qt::Horizontal, listPage);
        listSplit->setChildrenCollapsible(false);
        auto *listLay = new QHBoxLayout(listPage);
        listLay->setContentsMargins(0, 0, 0, 0);
        listLay->addWidget(listSplit);

        auto *listPane = new QWidget;
        auto *lpv = new QVBoxLayout(listPane);
        lpv->setContentsMargins(0, 0, 0, 0);
        lpv->setSpacing(0);
        m_table = new QTreeWidget;
        m_table->setRootIsDecorated(false);
        m_table->setUniformRowHeights(true);
        m_table->setItemsExpandable(true);
        m_table->setIndentation(0);
        m_table->setAlternatingRowColors(false);
        m_table->setSelectionMode(QAbstractItemView::SingleSelection);
        m_table->setSelectionBehavior(QAbstractItemView::SelectRows);
        m_table->setAllColumnsShowFocus(true);
        m_table->header()->setStretchLastSection(false);
        m_table->setFrameShape(QFrame::NoFrame);
        m_table->setItemDelegate(new TableRowDelegate(m_table));
        QFont head = small;
        head.setBold(true);
        m_table->header()->setFont(head);
        m_emptyPane = new QWidget;
        auto *ev = new QVBoxLayout(m_emptyPane);
        ev->setContentsMargins(16, 16, 16, 16);
        ev->setSpacing(8);
        ev->addStretch();
        auto *emptyInner = new QWidget;
        auto *eiv = new QVBoxLayout(emptyInner);
        eiv->setContentsMargins(0, 0, 0, 0);
        eiv->setSpacing(8);
        eiv->setAlignment(Qt::AlignHCenter);
        m_emptyTitle = new QLabel;
        QFont emptyTitleFont = body;
        emptyTitleFont.setBold(true);
        m_emptyTitle->setFont(emptyTitleFont);
        m_emptyTitle->setAlignment(Qt::AlignCenter);
        m_emptyTitle->setWordWrap(true);
        m_emptyDetail = new QLabel;
        m_emptyDetail->setAlignment(Qt::AlignCenter);
        m_emptyDetail->setWordWrap(true);
        m_emptyDetail->setFont(body);
        m_emptyDetail->setForegroundRole(QPalette::PlaceholderText);
        m_emptyDetail->setMaximumWidth(400);
        m_clearSearch = new QPushButton(QStringLiteral("Clear search"));
        m_clearSearch->hide();
        m_emptyRetry = new QPushButton(QStringLiteral("Try Again"));
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
        m_inspectorLay->setContentsMargins(16, 16, 16, 16);
        m_inspectorLay->setSpacing(10);
        m_inspectorScroll->setWidget(m_inspectorHost);

        listSplit->addWidget(listPane);
        listSplit->addWidget(m_inspectorScroll);
        listSplit->setStretchFactor(0, 1);
        listSplit->setStretchFactor(1, 0);
        listSplit->setSizes({760, 320});
        m_stack->addWidget(listPage);

        m_settings = buildSettings();
        m_stack->addWidget(m_settings);

        m_actionBar = new QWidget;
        m_actionBar->setAutoFillBackground(true);
        {
            QPalette ap = m_actionBar->palette();
            ap.setColor(QPalette::Window, ap.color(QPalette::Button));
            m_actionBar->setPalette(ap);
        }
        auto *ah = new QHBoxLayout(m_actionBar);
        ah->setContentsMargins(12, 6, 12, 6);
        m_actionCount = new QLabel;
        m_actionCount->setFont(small);
        m_actionBytes = new QLabel;
        m_actionBytes->setFont(small);
        m_clearSel = new QPushButton(QStringLiteral("Clear"));
        m_clearSel->setToolTip(QStringLiteral("Clear the current selection"));
        m_preview = new QPushButton(QStringLiteral("Preview Script"));
        m_markManualBtn = new QPushButton(QStringLiteral("Mark Manual"));
        m_markManualBtn->setToolTip(QStringLiteral("Mark selected distro packages as manually installed"));
        m_updateBtn = new QPushButton(QStringLiteral("Update"));
        m_deleteBtn = new QPushButton(QStringLiteral("Delete"));
        ah->addWidget(m_actionCount);
        ah->addWidget(m_actionBytes);
        ah->addStretch();
        ah->addWidget(m_clearSel);
        ah->addWidget(m_preview);
        ah->addWidget(m_markManualBtn);
        ah->addWidget(m_updateBtn);
        ah->addWidget(m_deleteBtn);
        m_actionBar->hide();

        rv->addWidget(tools);
        rv->addWidget(toolsRule);
        rv->addWidget(m_errorBar);
        rv->addWidget(m_stack, 1);
        rv->addWidget(m_actionBar);

        outer->addWidget(m_sidebar);
        outer->addWidget(right);
        outer->setStretchFactor(0, 0);
        outer->setStretchFactor(1, 1);
        outer->setSizes({220, 960});
        setCentralWidget(outer);

        auto *scanMenu = menuBar()->addMenu(QStringLiteral("Scan"));
        auto *rescanAct = scanMenu->addAction(QStringLiteral("Rescan"));
        rescanAct->setShortcut(QKeySequence::Refresh);
        connect(rescanAct, &QAction::triggered, this, &MainWindow::rescan);
        auto *helpMenu = menuBar()->addMenu(QStringLiteral("Help"));
        auto *aboutAct = helpMenu->addAction(QStringLiteral("About AppAttic"));
        connect(aboutAct, &QAction::triggered, this, [this] {
            QMessageBox::about(
                this,
                QStringLiteral("AppAttic"),
                QStringLiteral("AppAttic 1.0.0\nLeftovers, stale apps, outdated packages.")
            );
        });

        connect(m_sidebar, &QListWidget::currentRowChanged, this, &MainWindow::showPage);
        connect(m_rescan, &QPushButton::clicked, this, &MainWindow::rescan);
        connect(m_search, &QLineEdit::textChanged, this, [this] { fillCurrent(); });
        connect(m_filter, &QComboBox::currentIndexChanged, this, [this] { fillCurrent(); });
        connect(m_clearSearch, &QPushButton::clicked, this, [this] { m_search->clear(); });
        connect(m_emptyRetry, &QPushButton::clicked, this, &MainWindow::rescan);
        connect(m_selectAll, &QPushButton::clicked, this, &MainWindow::toggleSelectAll);
        connect(m_table, &QTreeWidget::currentItemChanged, this, [this](QTreeWidgetItem *cur, QTreeWidgetItem *) {
            m_selectedUid = cur ? cur->data(0, Qt::UserRole).toString() : QString();
            rebuildInspector();
        });
        connect(m_table, &QTreeWidget::itemClicked, this, [this](QTreeWidgetItem *it, int col) {
            if (!it || col != 0) return;
            const QString uid = it->data(0, Qt::UserRole).toString();
            if (uid.isEmpty() || it->data(0, Qt::UserRole + 1).isValid()) return;
            const Finding *f = findingByUid(uid);
            if (!f) return;
            if (m_markedManual.contains(uid)) {
                m_markedManual.remove(uid);
            } else if (canMarkCleanup(*f, currentPage())) {
                if (m_marked.contains(uid)) m_marked.remove(uid);
                else {
                    m_marked.insert(uid);
                    m_markedManual.remove(uid);
                }
            } else {
                return;
            }
            it->setText(
                0,
                (m_marked.contains(uid) || m_markedManual.contains(uid))
                    ? QStringLiteral("in")
                    : QString()
            );
            m_selectAll->setText(
                allMarked(currentPage(), visibleRows(currentPage()))
                    ? QStringLiteral("Deselect All")
                    : QStringLiteral("Select All")
            );
            rebuildInspector();
            refreshActionBar();
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
        applySystemAppearance();
        applyInitialPage();
        if (!m_settingsError) rescan();
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, [this](Qt::ColorScheme) {
            applySystemAppearance();
            fillCurrent();
        });
#endif
    }

    ~MainWindow() override {
        m_scanThread->quit();
        m_scanThread->wait();
        delete m_worker;
    }

signals:
    void requestScan(const QString &core, const QStringList &pluginSpecs);

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
            showError(QStringLiteral("Scan engine is missing. Rebuild the app, then click Rescan."));
            fillCurrent();
            return;
        }
        m_scanning = true;
        m_rescan->setEnabled(false);
        m_selectAll->setEnabled(false);
        statusBar()->showMessage(QStringLiteral("Scanning…"));
        fillCurrent();
        emit requestScan(core, taggedPluginSpecs(out));
    }

    void scanFinished(const QByteArray &blobs, const QString &err, int rc) {
        m_scanning = false;
        m_hasScanned = true;
        m_rescan->setEnabled(true);
        m_findings.clear();
        for (const QByteArray &line : blobs.split('\n')) {
            if (line.isEmpty()) continue;
            parseBlob(line);
        }
        enrichFindingsUsageTiming(m_findings);
        m_scanOk = (rc == 0);
        m_scanAt = QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm"));
        if (rc != 0) {
            showError(err.isEmpty() ? QStringLiteral("Scan failed. Click Rescan to try again.") : err);
        } else if (!m_settingsError) {
            m_errorBar->hide();
            m_error->clear();
            statusBar()->showMessage(
                scanSummaryMessage(
                    countPage(Page::Leftovers),
                    countPage(Page::Stale),
                    countPage(Page::Outdated),
                    countPage(Page::Packages),
                    m_scanAt
                )
            );
        } else {
            statusBar()->showMessage(
                QStringLiteral("%1 plugin findings").arg(m_findings.size())
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
                    .arg(cleanupMarkCount()),
                QStringLiteral("Delete")
            );
            return;
        }
        runScript(script, QStringLiteral("Removing selected items…"));
    }

    void confirmUpdate() {
        if (m_scanning) return;
        const QString script = updateScript();
        if (!scriptHasCommands(script)) return;
        if (m_confirmDelete) {
            showScriptSheet(
                ScriptKind::Update,
                script,
                QStringLiteral("Update %1 selected packages?").arg(updateMarkCount()),
                QStringLiteral("Update")
            );
            return;
        }
        runScript(script, QStringLiteral("Updating selected packages…"));
    }

    void confirmMarkManual() {
        if (m_scanning) return;
        const QString script = markManualScript();
        if (!scriptHasCommands(script)) return;
        if (m_confirmDelete) {
            showScriptSheet(
                ScriptKind::MarkManual,
                script,
                QStringLiteral("Mark %1 packages as manually installed?").arg(m_markedManual.size()),
                QStringLiteral("Mark Manual")
            );
            return;
        }
        runScript(script, QStringLiteral("Marking packages as manually installed…"));
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
        QFont body = bodyFont();
        title->setFont(body);
        title->setWordWrap(true);
        auto *hint = new QLabel(QStringLiteral("Review every line before running."));
        QFont small = smallFont();
        hint->setFont(small);
        hint->setForegroundRole(QPalette::PlaceholderText);
        hint->setVisible(!question.isEmpty());
        auto *edit = new QPlainTextEdit;
        QFont mono = smallFont();
        mono.setFamily(QStringLiteral("monospace"));
        edit->setFont(mono);
        edit->setReadOnly(true);
        edit->setPlainText(script);
        auto *box = new QDialogButtonBox;
        auto *copy = box->addButton(QStringLiteral("Copy"), QDialogButtonBox::ActionRole);
        connect(copy, &QPushButton::clicked, this, [script, copy] {
            if (QClipboard *cb = QGuiApplication::clipboard()) {
                cb->setText(script);
                copy->setText(QStringLiteral("Copied"));
                copy->setEnabled(false);
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
            auto *go = box->addButton(runLabel, QDialogButtonBox::AcceptRole);
            Q_UNUSED(go);
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
            if (kind == ScriptKind::Delete) progress = QStringLiteral("Removing selected items…");
            else if (kind == ScriptKind::Update) progress = QStringLiteral("Updating selected packages…");
            else if (kind == ScriptKind::MarkManual) {
                progress = QStringLiteral("Marking packages as manually installed…");
            }
            runScript(script, progress);
        }
    }
    Page currentPage() const {
        const int row = m_sidebar->currentRow();
        if (row < 0) return Page::Overview;
        return static_cast<Page>(row);
    }

    void applyInitialPage() {
        const QByteArray env = qgetenv("APPATTIC_PAGE");
        const QString v = QString::fromUtf8(env);
        int row = 0;
        if (v == QLatin1String("leftovers")) row = 1;
        else if (v == QLatin1String("stale")) row = 2;
        else if (v == QLatin1String("outdated")) row = 3;
        else if (v == QLatin1String("packages")) row = 4;
        else if (v == QLatin1String("settings")) row = 5;
        m_sidebar->setCurrentRow(row);
    }

    void showError(const QString &msg) {
        const Tone t = toneFrom(palette());
        QPalette p = m_error->palette();
        p.setColor(QPalette::WindowText, t.red);
        m_error->setPalette(p);
        m_error->setText(msg);
        m_errorBar->show();
        statusBar()->showMessage(msg);
    }

    QWidget *buildOverview() {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(0, 0, 0, 0);
        v->setSpacing(0);
        auto *stats = new QWidget;
        auto *sh = new QHBoxLayout(stats);
        sh->setContentsMargins(16, 12, 16, 12);
        sh->setSpacing(28);
        m_statInstalled = addStat(sh, QStringLiteral("Installed"));
        m_statLeftovers = addStat(sh, QStringLiteral("Leftovers"));
        m_statLeftoverData = addStat(sh, QStringLiteral("Leftover data"));
        m_statStale = addStat(sh, QStringLiteral("Stale"));
        m_statOutdated = addStat(sh, QStringLiteral("Outdated"));
        m_statPackages = addStat(sh, QStringLiteral("Packages"));
        m_statScan = addStat(sh, QStringLiteral("Last scan"));
        sh->addStretch();
        v->addWidget(stats);

        auto *line = new QFrame;
        line->setFrameShape(QFrame::HLine);
        line->setFrameShadow(QFrame::Plain);
        v->addWidget(line);

        auto *cols = new QSplitter(Qt::Horizontal);
        cols->setChildrenCollapsible(false);
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
        connect(m_ovLeftovers, &QTreeWidget::itemClicked, this, [this](QTreeWidgetItem *it, int) {
            m_selectedUid = it->data(0, Qt::UserRole).toString();
            m_sidebar->setCurrentRow(int(Page::Leftovers));
        });
        connect(m_ovStale, &QTreeWidget::itemClicked, this, [this](QTreeWidgetItem *it, int) {
            m_selectedUid = it->data(0, Qt::UserRole).toString();
            m_sidebar->setCurrentRow(int(Page::Stale));
        });
        connect(m_ovOutdated, &QTreeWidget::itemClicked, this, [this](QTreeWidgetItem *it, int) {
            m_selectedUid = it->data(0, Qt::UserRole).toString();
            m_sidebar->setCurrentRow(int(Page::Outdated));
        });
        return w;
    }

    QLabel *addStat(QHBoxLayout *sh, const QString &label) {
        auto *box = new QWidget;
        auto *bv = new QVBoxLayout(box);
        bv->setContentsMargins(0, 0, 0, 0);
        bv->setSpacing(2);
        auto *l = new QLabel(label);
        l->setFont(smallFont());
        l->setForegroundRole(QPalette::PlaceholderText);
        auto *val = new QLabel(QStringLiteral("unknown"));
        val->setFont(bodyFont());
        bv->addWidget(l);
        bv->addWidget(val);
        sh->addWidget(box);
        return val;
    }

    QTreeWidget *makeOverviewTree(const QString &trailing) {
        auto *t = new QTreeWidget;
        t->setRootIsDecorated(false);
        t->setUniformRowHeights(true);
        t->setIndentation(0);
        t->setHeaderLabels({QStringLiteral("Name"), QStringLiteral("What"), trailing});
        t->header()->setStretchLastSection(false);
        t->header()->setSectionResizeMode(0, QHeaderView::Stretch);
        t->header()->setSectionResizeMode(1, QHeaderView::Stretch);
        t->header()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
        t->setFrameShape(QFrame::NoFrame);
        QFont head = smallFont();
        head.setBold(true);
        t->header()->setFont(head);
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
        QFont f = bodyFont();
        f.setBold(true);
        h->setFont(f);
        h->setContentsMargins(16, 8, 16, 8);
        h->setAutoFillBackground(true);
        QPalette p = h->palette();
        p.setColor(QPalette::Window, p.color(QPalette::Button));
        h->setPalette(p);
        auto *empty = new QLabel;
        empty->setAlignment(Qt::AlignCenter);
        empty->setWordWrap(true);
        empty->setContentsMargins(16, 16, 16, 16);
        empty->setFont(bodyFont());
        empty->setForegroundRole(QPalette::PlaceholderText);
        v->addWidget(h);
        v->addWidget(tree, 1);
        v->addWidget(empty, 1);
        *emptyOut = empty;
        return w;
    }

    QWidget *buildSettings() {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(16, 16, 16, 16);
        v->setSpacing(16);
        auto *row = new QHBoxLayout;
        row->setSpacing(32);

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
        m_ignoredList = new QLabel;
        m_ignoredList->setWordWrap(true);
        QFont small = smallFont();
        m_ignoredList->setFont(small);
        m_clearIgnored = new QPushButton(QStringLiteral("Clear ignored leftovers"));
        ignCol.second->addWidget(m_ignoredList);
        ignCol.second->addWidget(m_clearIgnored);

        row->addWidget(scanCol.first, 1);
        row->addWidget(delCol.first, 1);
        row->addWidget(ignCol.first, 1);
        v->addLayout(row);
        v->addStretch();
        auto *ver = new QLabel(QStringLiteral("AppAttic 1.0.0"));
        ver->setFont(small);
        ver->setForegroundRole(QPalette::PlaceholderText);
        v->addWidget(ver);

        connect(m_confirmBox, &QCheckBox::toggled, this, [this](bool on) {
            m_confirmDelete = on;
            persistSettings();
        });
        connect(m_clearIgnored, &QPushButton::clicked, this, [this] {
            m_ignored.clear();
            persistSettings();
            fillCurrent();
        });
        return w;
    }

    std::pair<QWidget *, QVBoxLayout *> section(const QString &title) {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(0, 0, 0, 0);
        v->setSpacing(8);
        auto *t = new QLabel(title);
        QFont f = bodyFont();
        f.setBold(true);
        t->setFont(f);
        v->addWidget(t);
        return {w, v};
    }

    QLabel *hintLabel(const QString &text) {
        auto *l = new QLabel(text);
        l->setFont(smallFont());
        l->setWordWrap(true);
        l->setForegroundRole(QPalette::PlaceholderText);
        return l;
    }

    void parseBlob(const QByteArray &line) {
        appendFindingsFromBlob(m_findings, line);
    }

    QVector<Finding> visibleRows(Page page) const {
        QVector<Finding> rows;
        const QString q = m_search->text().trimmed();
        const QString filt = m_filter->currentData().toString();
        for (const Finding &f : m_findings) {
            if (!matchPage(f, page)) continue;
            if (page == Page::Leftovers && leftoverIsIgnored(f, m_ignored)) continue;
            if (page == Page::Packages) {
                if (filt == QLatin1String("globals") && !isGlobalKind(f)) continue;
                if (filt == QLatin1String("leaves") && isGlobalKind(f)) continue;
            }
            if (!q.isEmpty()) {
                const QString hay = (
                    displayName(f) + f.path + f.kind + managerLabel(f)
                    + f.status + f.packagedPath + f.summary + f.reason
                    + f.extraPaths.join(QLatin1Char(' '))
                ).toLower();
                if (!hay.contains(q.toLower())) continue;
            }
            rows.push_back(f);
        }
        std::sort(rows.begin(), rows.end(), [](const Finding &a, const Finding &b) {
            return a.bytes > b.bytes;
        });
        return rows;
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
        refreshSidebarCounts();
        const bool settings = page == Page::Settings;
        const bool overview = page == Page::Overview;
        m_stack->setCurrentIndex(settings ? 2 : (overview ? 0 : 1));
        const bool list = !settings && !overview;
        m_search->setVisible(list);
        m_filter->setVisible(page == Page::Packages);
        m_selectAll->setVisible(list);
        m_count->setVisible(list || overview);
        if (overview) fillOverview();
        else if (list) fillTable(page);
        else refreshIgnoredLabel();
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

    void fillOverview() {
        const Tone t = toneFrom(palette());
        const int leftovers = countPage(Page::Leftovers);
        const int stale = countPage(Page::Stale);
        const int outdated = countPage(Page::Outdated);
        const int packages = countPage(Page::Packages);
        qint64 leftoverBytes = 0;
        for (const Finding &f : m_findings) {
            if (!isLeftover(f) || f.bytes <= 0 || leftoverIsIgnored(f, m_ignored)) continue;
            leftoverBytes = addBytes(leftoverBytes, f.bytes);
        }
        const bool scanningEmpty = isScanPending() && m_findings.isEmpty();
        const bool settingsBlocked = m_settingsError && !m_hasScanned && m_findings.isEmpty() && !m_scanning;
        const QString pending = QStringLiteral("…");
        const QString blockedMark = QStringLiteral("-");
        m_statInstalled->setText(QStringLiteral("Not scanned"));
        m_statInstalled->setToolTip(
            QStringLiteral("This Linux scan does not count installed apps.")
        );
        auto statCount = [&](int n) {
            if (scanningEmpty) return pending;
            if (settingsBlocked) return blockedMark;
            return QString::number(n);
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
                                             : (leftoverBytes > 0 ? humanSize(leftoverBytes)
                                                                  : (leftovers > 0 ? QStringLiteral("unknown") : humanSize(0))))
        );
        m_statStale->setText(statCount(stale));
        m_statOutdated->setText(statCount(outdated));
        m_statPackages->setText(statCount(packages));
        m_statScan->setText(
            m_scanning ? QStringLiteral("Scanning…")
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
                return a.bytes > b.bytes;
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
                it->setToolTip(0, displayName(f));
                it->setToolTip(1, whatText(f, page));
                if (!f.path.isEmpty()) it->setToolTip(2, f.path);
                QFont body = bodyFont();
                QFont small = smallFont();
                it->setFont(0, body);
                it->setFont(1, small);
                it->setFont(2, small);
                it->setForeground(1, t.dim);
                it->setForeground(2, t.dim);
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
        m_count->setText(m_scanning ? QStringLiteral("Scanning") : QString());
    }

    void setupColumns(Page page) {
        m_table->setSortingEnabled(false);
        QStringList headers;
        switch (page) {
        case Page::Leftovers:
            headers = {QString(), QStringLiteral("Name"), QStringLiteral("Location"),
                       QStringLiteral("Modified"), QStringLiteral("Size")};
            break;
        case Page::Stale:
            headers = {QString(), QStringLiteral("Name"), QStringLiteral("Status"),
                       QStringLiteral("Last used"), QStringLiteral("Size")};
            break;
        case Page::Outdated:
            headers = {QString(), QStringLiteral("Name"), QStringLiteral("Manager"),
                       QStringLiteral("Current → Latest")};
            break;
        case Page::Packages:
            headers = {QString(), QStringLiteral("Name"), QStringLiteral("Manager"),
                       QStringLiteral("Kind"), QStringLiteral("Size")};
            break;
        default:
            headers = {QString(), QStringLiteral("Name")};
            break;
        }
        m_table->setColumnCount(headers.size());
        m_table->setHeaderLabels(headers);
        if (QTreeWidgetItem *head = m_table->headerItem()) {
            head->setToolTip(
                0,
                QStringLiteral("Click to include the item in cleanup, update, or remove")
            );
        }
        m_table->header()->setSectionResizeMode(0, QHeaderView::Fixed);
        m_table->setColumnWidth(0, 28);
        m_table->header()->setSectionResizeMode(1, QHeaderView::Stretch);
        for (int c = 2; c < headers.size(); ++c) {
            m_table->header()->setSectionResizeMode(c, QHeaderView::ResizeToContents);
        }
    }

    void fillTable(Page page) {
        setupColumns(page);
        const Tone t = toneFrom(palette());
        const QVector<Finding> rows = visibleRows(page);
        const QSignalBlocker block(m_table);
        m_table->clear();
        bool hasKids = false;
        for (const Finding &f : rows) {
            if (!f.children.isEmpty()) {
                hasKids = true;
                break;
            }
        }
        m_table->setRootIsDecorated(hasKids && page == Page::Packages);
        m_table->setIndentation(hasKids && page == Page::Packages ? 18 : 0);
        QFont body = bodyFont();
        QFont small = smallFont();
        QFont mark = small;
        mark.setBold(true);
        QTreeWidgetItem *select = nullptr;
        for (const Finding &f : rows) {
            auto *it = new QTreeWidgetItem(m_table);
            const QString uid = f.uid();
            it->setData(0, Qt::UserRole, uid);
            it->setFont(0, mark);
            const bool markedCleanup = m_marked.contains(uid);
            const bool markedKeep = m_markedManual.contains(uid);
            it->setText(0, (markedCleanup || markedKeep) ? QStringLiteral("in") : QString());
            it->setForeground(0, palette().color(QPalette::Highlight));
            it->setText(1, displayName(f));
            it->setFont(1, body);
            it->setSizeHint(0, QSize(28, rowPx()));
            if (markedCleanup) {
                it->setToolTip(0, QStringLiteral("Included. Click to remove from the selection."));
            } else if (markedKeep) {
                it->setToolTip(
                    0,
                    QStringLiteral("Marked as manually installed. Click to remove from the selection.")
                );
            } else if (canMarkCleanup(f, page)) {
                it->setToolTip(
                    0,
                    QStringLiteral("Click to include in cleanup, update, or remove.")
                );
            } else {
                it->setToolTip(0, QString());
            }
            it->setToolTip(1, displayName(f));
            if (!f.path.isEmpty()) it->setToolTip(1, displayName(f) + QLatin1Char('\n') + f.path);
            switch (page) {
            case Page::Leftovers:
                it->setText(2, locationLabel(f));
                it->setText(3, modifiedLabel(f));
                it->setText(4, f.bytes >= 0 ? humanSize(f.bytes) : QStringLiteral("unknown"));
                it->setFont(2, small);
                it->setFont(3, small);
                it->setFont(4, small);
                it->setForeground(2, t.dim);
                it->setForeground(3, t.dim);
                it->setForeground(4, t.dim);
                if (isShadowFinding(f)) {
                    it->setForeground(1, t.amber);
                    it->setForeground(2, t.amber);
                }
                break;
            case Page::Stale:
                it->setText(2, statusLabel(f));
                it->setText(3, modifiedLabel(f));
                it->setText(4, f.bytes >= 0 ? humanSize(f.bytes) : QStringLiteral("unknown"));
                it->setFont(2, small);
                it->setFont(3, small);
                it->setFont(4, small);
                it->setForeground(2, statusColor(f, t, page));
                it->setForeground(3, t.dim);
                it->setForeground(4, t.dim);
                break;
            case Page::Outdated: {
                QString ver = QStringLiteral("-");
                if (!f.currentVersion.isEmpty() || !f.latestVersion.isEmpty()) {
                    ver = (f.currentVersion.isEmpty() ? QStringLiteral("-") : f.currentVersion)
                        + QStringLiteral(" → ") + (f.latestVersion.isEmpty() ? QStringLiteral("?") : f.latestVersion);
                }
                it->setText(2, managerLabel(f));
                it->setText(3, ver);
                it->setFont(2, small);
                it->setFont(3, small);
                it->setForeground(2, t.dim);
                it->setForeground(3, t.amber);
                break;
            }
            case Page::Packages:
                it->setText(2, managerLabel(f));
                it->setText(3, humanKind(f.kind));
                it->setText(4, f.bytes >= 0 ? humanSize(f.bytes) : QStringLiteral("unknown"));
                it->setFont(2, small);
                it->setFont(3, small);
                it->setFont(4, small);
                it->setForeground(2, t.dim);
                it->setForeground(3, statusColor(f, t, page));
                it->setForeground(4, t.dim);
                for (const QString &child : f.children) {
                    auto *kid = new QTreeWidgetItem(it);
                    kid->setText(1, child);
                    kid->setFont(1, small);
                    kid->setForeground(1, t.dim);
                    kid->setData(0, Qt::UserRole, uid);
                    kid->setData(0, Qt::UserRole + 1, child);
                    kid->setSizeHint(0, QSize(28, rowPx()));
                }
                break;
            default:
                break;
            }
            if (uid == m_selectedUid) select = it;
        }
        if (!select && m_table->topLevelItemCount() > 0) {
            select = m_table->topLevelItem(0);
            m_selectedUid = select->data(0, Qt::UserRole).toString();
        }
        if (select) m_table->setCurrentItem(select);
        else m_selectedUid.clear();

        const bool scanningEmpty = isScanPending() && m_findings.isEmpty();
        const bool scanFailed = m_hasScanned && !m_scanning && !m_scanOk && m_findings.isEmpty();
        const bool settingsBlocked = m_settingsError && !m_hasScanned && m_findings.isEmpty() && !m_scanning;
        if (rows.isEmpty()) {
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
                m_emptyDetail->setText(pageEmptyDetail(
                    page,
                    scanningEmpty,
                    scanFailed,
                    m_search->text(),
                    m_ignored.size(),
                    m_filter->currentData().toString(),
                    m_error->text()
                ));
            }
            m_clearSearch->setVisible(
                !m_search->text().trimmed().isEmpty() && !scanningEmpty && !scanFailed && !settingsBlocked
            );
            m_emptyRetry->setVisible((scanFailed || settingsBlocked) && !scanningEmpty);
        } else {
            m_table->show();
            m_emptyPane->hide();
            m_clearSearch->hide();
            m_emptyRetry->hide();
        }
        QString count = countLabel(page, rows.size());
        if (scanningEmpty) {
            count = QStringLiteral("Scanning");
        } else if (m_scanning) {
            count += QStringLiteral(" · Scanning");
        } else if (!m_scanAt.isEmpty()) {
            count += QStringLiteral(" · ") + m_scanAt;
        }
        m_count->setText(count);
        bool anyMarkable = false;
        for (const Finding &f : rows) {
            if (canMarkCleanup(f, page)) {
                anyMarkable = true;
                break;
            }
        }
        m_selectAll->setText(allMarked(page, rows) ? QStringLiteral("Deselect All") : QStringLiteral("Select All"));
        m_selectAll->setVisible(anyMarkable);
        m_selectAll->setEnabled(anyMarkable && !m_scanning);
        rebuildInspector();
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
            return n == 1 ? QStringLiteral("1 leftover") : QString::number(n) + QStringLiteral(" leftovers");
        case Page::Stale:
            return n == 1 ? QStringLiteral("1 stale app") : QString::number(n) + QStringLiteral(" stale apps");
        case Page::Outdated:
            return n == 1 ? QStringLiteral("1 outdated package") : QString::number(n) + QStringLiteral(" outdated packages");
        case Page::Packages:
            return n == 1 ? QStringLiteral("1 package") : QString::number(n) + QStringLiteral(" packages");
        default:
            return QString::number(n);
        }
    }

    bool isScanPending() const {
        const bool noError = !m_error || m_error->text().isEmpty();
        return m_scanning || (!m_hasScanned && noError);
    }

    QString emptyDetail(Page page) const {
        return pageEmptyDetail(
            page,
            isScanPending() && m_findings.isEmpty(),
            m_hasScanned && !m_scanning && !m_scanOk && m_findings.isEmpty(),
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
        while (QLayoutItem *item = m_inspectorLay->takeAt(0)) {
            if (item->widget()) item->widget()->deleteLater();
            delete item;
        }
    }

    QLabel *inspectorLabel(const QString &text, int pt, bool bold, const QColor &color, bool mono = false) {
        auto *l = new QLabel(text);
        QFont f = font();
        f.setPointSize(pt);
        f.setBold(bold);
        if (mono) f.setFamily(QStringLiteral("monospace"));
        l->setFont(f);
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
        h->setSpacing(8);
        const Tone t = toneFrom(palette());
        auto *k = inspectorLabel(label, 11, false, t.dim);
        k->setFixedWidth(88);
        k->setAlignment(Qt::AlignRight | Qt::AlignTop);
        auto *v = inspectorLabel(value, mono ? 11 : 13, false, color, mono);
        h->addWidget(k);
        h->addWidget(v, 1);
        m_inspectorLay->addWidget(row);
    }

    void rebuildInspector() {
        clearInspector();
        const Page page = currentPage();
        const Tone t = toneFrom(palette());
        const Finding *f = findingByUid(m_selectedUid);
        if (page == Page::Overview || page == Page::Settings) return;
        if (isScanPending() && m_findings.isEmpty()) {
            m_inspectorLay->addWidget(inspectorLabel(QStringLiteral("Scanning"), 13, true, t.text));
            m_inspectorLay->addWidget(inspectorLabel(
                QStringLiteral("Results appear here when the scan finishes."),
                13,
                false,
                t.dim
            ));
            m_inspectorLay->addStretch();
            return;
        }
        if (!f || !matchPage(*f, page)) {
            QString title = QStringLiteral("Select an item");
            QString body = QStringLiteral("What it is, why it was flagged, plus path and size.");
            if (visibleRows(page).isEmpty()) {
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
            m_inspectorLay->addWidget(inspectorLabel(title, 13, true, t.text));
            m_inspectorLay->addWidget(inspectorLabel(body, 13, false, t.dim));
            m_inspectorLay->addStretch();
            return;
        }
        m_inspectorLay->addWidget(inspectorLabel(displayName(*f), 13, true, t.text));
        addFact(QStringLiteral("What"), whatText(*f, page), t.text);
        addFact(QStringLiteral("Why"), whyText(*f), t.text);
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
        addFact(QStringLiteral("Modified"), modifiedLabel(*f), t.text);
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

        m_inspectorLay->addStretch();

        if (canMarkCleanup(*f, page)) {
            auto *inc = new QCheckBox(
                page == Page::Outdated ? QStringLiteral("Include in update")
                                       : (page == Page::Packages ? QStringLiteral("Include in remove")
                                                                 : QStringLiteral("Include in cleanup"))
            );
            inc->setChecked(m_marked.contains(f->uid()));
            const QString uid = f->uid();
            connect(inc, &QCheckBox::toggled, this, [this, uid](bool on) {
                if (on) {
                    m_marked.insert(uid);
                    m_markedManual.remove(uid);
                } else {
                    m_marked.remove(uid);
                }
                for (int i = 0; i < m_table->topLevelItemCount(); ++i) {
                    QTreeWidgetItem *it = m_table->topLevelItem(i);
                    if (it->data(0, Qt::UserRole).toString() != uid) continue;
                    it->setText(0, on ? QStringLiteral("in") : QString());
                    break;
                }
                m_selectAll->setText(
                    allMarked(currentPage(), visibleRows(currentPage()))
                        ? QStringLiteral("Deselect All")
                        : QStringLiteral("Select All")
                );
                refreshActionBar();
            });
            m_inspectorLay->addWidget(inc);
        }
        if (page == Page::Packages && canMarkManual(*f)) {
            auto *keep = new QCheckBox(QStringLiteral("Mark as manually installed"));
            keep->setChecked(m_markedManual.contains(f->uid()));
            const QString uid = f->uid();
            connect(keep, &QCheckBox::toggled, this, [this, uid](bool on) {
                if (on) {
                    m_markedManual.insert(uid);
                    m_marked.remove(uid);
                } else {
                    m_markedManual.remove(uid);
                }
                for (int i = 0; i < m_table->topLevelItemCount(); ++i) {
                    QTreeWidgetItem *it = m_table->topLevelItem(i);
                    if (it->data(0, Qt::UserRole).toString() != uid) continue;
                    it->setText(
                        0,
                        (m_marked.contains(uid) || m_markedManual.contains(uid))
                            ? QStringLiteral("in")
                            : QString()
                    );
                    break;
                }
                refreshActionBar();
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
            });
            m_inspectorLay->addWidget(ign);
        }
    }

    QString emptyTitle(Page page) const {
        return pageEmptyTitle(
            page,
            isScanPending() && m_findings.isEmpty(),
            m_hasScanned && !m_scanning && !m_scanOk && m_findings.isEmpty()
        );
    }

    void refreshActionBar() {
        qint64 bytes = 0;
        int n = 0;
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid()) && !m_markedManual.contains(f.uid())) continue;
            ++n;
            if (f.bytes > 0) bytes = addBytes(bytes, f.bytes);
        }
        m_actionBar->setVisible(n > 0);
        m_actionCount->setText(QStringLiteral("%1 selected").arg(n));
        m_actionBytes->setText(bytes > 0 ? humanSize(bytes) : QString());
        const bool busy = m_scanning;
        const bool canDelete = scriptHasCommands(cleanupScript());
        const bool canUpdate = scriptHasCommands(updateScript());
        const bool canKeep = scriptHasCommands(markManualScript());
        if (m_clearSel) m_clearSel->setEnabled(!busy);
        if (m_preview) m_preview->setEnabled(!busy);
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
            if (!m_marked.contains(f.uid())) continue;
            if (isOutdated(f) && !isLeftover(f) && !isStale(f) && !isPackage(f)) continue;
            ++n;
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

    QString cleanupScript() const {
        QStringList lines;
        lines << QStringLiteral("#!/bin/sh") << QStringLiteral("set -e")
              << QStringLiteral("# AppAttic. Review before running.");
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid())) continue;
            if (isOutdated(f) && !isLeftover(f) && !isStale(f) && !isPackage(f)) continue;
            const QString cmd = isLeftover(f) ? leftoverCleanupCommand(f) : f.command;
            if (cmd.isEmpty()) continue;
            lines << cmd;
        }
        return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
    }

    QString updateScript() const {
        QStringList lines;
        lines << QStringLiteral("#!/bin/sh") << QStringLiteral("set -e")
              << QStringLiteral("# AppAttic. Review before running.");
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid()) || !isOutdated(f)) continue;
            if (!f.updatable) continue;
            const QString cmd = f.updateCommand.isEmpty() ? f.command : f.updateCommand;
            if (cmd.isEmpty()) continue;
            lines << cmd;
        }
        return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
    }

    QString markManualScript() const {
        QStringList lines;
        lines << QStringLiteral("#!/bin/sh") << QStringLiteral("set -e")
              << QStringLiteral("# AppAttic. Review before running.")
              << QStringLiteral("# Mark as manually installed (keep)");
        for (const Finding &f : m_findings) {
            if (!m_markedManual.contains(f.uid())) continue;
            const QString cmd = markManualCommand(f);
            if (cmd.isEmpty()) continue;
            lines << cmd;
        }
        return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
    }

    static QString scriptBodyLines(const QString &script) {
        QString out;
        for (const QString &line : script.split(QLatin1Char('\n'))) {
            const QString t = line.trimmed();
            if (t.isEmpty() || t.startsWith(QLatin1Char('#')) || t == QLatin1String("#!/bin/sh")
                || t.startsWith(QLatin1String("set "))) {
                continue;
            }
            out += line + QLatin1Char('\n');
        }
        return out;
    }

    QString previewAllScript() const {
        QString out = cleanupScript();
        if (scriptHasCommands(updateScript())) {
            out += QStringLiteral("\n# Update selected packages\n");
            out += scriptBodyLines(updateScript());
        }
        if (scriptHasCommands(markManualScript())) {
            out += QStringLiteral("\n# Mark as manually installed. Delete in the UI does not run these lines.\n");
            out += scriptBodyLines(markManualScript());
        }
        return out;
    }

    void runScript(const QString &script, const QString &progress) {
        if (m_scanning) return;
        QTemporaryFile tmp(QDir::temp().filePath(QStringLiteral("appattic-XXXXXX.sh")));
        tmp.setAutoRemove(false);
        if (!tmp.open()) {
            showError(QStringLiteral("Could not write the script to run."));
            return;
        }
        tmp.write(script.toUtf8());
        tmp.close();
        QFile::setPermissions(tmp.fileName(), QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        m_scanning = true;
        m_rescan->setEnabled(false);
        statusBar()->showMessage(progress);
        refreshActionBar();
        auto *proc = new QProcess(this);
        connect(proc, &QProcess::finished, this, [this, proc, path = tmp.fileName()](int code) {
            QFile::remove(path);
            m_scanning = false;
            m_rescan->setEnabled(true);
            if (code != 0) {
                QString err = redactHomePaths(QString::fromUtf8(proc->readAllStandardError()).trimmed());
                if (err.isEmpty()) {
                    err = QStringLiteral("The script failed (exit %1). Selected items were kept.").arg(code);
                } else if (err.size() > 400) {
                    err = err.left(400);
                }
                showError(err);
                refreshActionBar();
            } else {
                if (!m_settingsError) {
                    m_errorBar->hide();
                    m_error->clear();
                }
                statusBar()->showMessage(QStringLiteral("Finished. Scanning again…"));
                m_marked.clear();
                m_markedManual.clear();
                rescan();
            }
            proc->deleteLater();
        });
        connect(proc, &QProcess::errorOccurred, this, [this, proc, path = tmp.fileName()](QProcess::ProcessError err) {
            if (err != QProcess::FailedToStart) return;
            QFile::remove(path);
            m_scanning = false;
            m_rescan->setEnabled(true);
            showError(QStringLiteral("Could not run the script."));
            refreshActionBar();
            proc->deleteLater();
        });
        proc->start(QStringLiteral("/bin/sh"), {tmp.fileName()});
    }

    void applySystemAppearance() {
        if (!m_table || m_applyingAppearance) return;
        m_applyingAppearance = true;
        resetWidgetPalette(m_table);
        resetWidgetPalette(m_inspectorHost);
        resetWidgetPalette(m_inspectorScroll);
        resetWidgetPalette(m_emptyPane);
        resetWidgetPalette(m_emptyTitle);
        resetWidgetPalette(m_emptyDetail);
        resetWidgetPalette(m_ovLeftovers);
        resetWidgetPalette(m_ovStale);
        resetWidgetPalette(m_ovOutdated);
        if (m_sidebar) m_sidebar->setAutoFillBackground(false);
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
        refreshIgnoredLabel();
    }

    void loadSettings() {
        m_settingsError = false;
        const QString path = settingsFilePath();
        QFile f(path);
        if (!f.exists()) {
            bool hadLegacy = false;
            const AppSettings s = migrateLegacyQSettings(&hadLegacy);
            applyLoadedSettings(s);
            if (hadLegacy) persistSettings();
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

    void persistSettings() {
        if (m_settingsError) return;
        AppSettings s;
        s.confirmDelete = m_confirmDelete;
        s.includeSystem = m_includeSystemOn;
        s.ignoredLeftoverPaths = QStringList(m_ignored.begin(), m_ignored.end());
        const QString path = settingsFilePath();
        const QFileInfo fi(path);
        if (!QDir().mkpath(fi.absolutePath())) {
            showError(settingsUnwritableMessage(path));
            return;
        }
        if (QFileInfo(fi.absolutePath()).fileName().compare(
                QStringLiteral("appattic"), Qt::CaseInsensitive) == 0) {
            restrictOwnerOnlyDir(fi.absolutePath());
        }
        QSaveFile f(path);
        if (!f.open(QIODevice::WriteOnly)) {
            showError(settingsUnwritableMessage(path));
            return;
        }
        const QByteArray raw = encodeSettingsJson(s);
        if (f.write(raw) != raw.size() || !f.commit()) {
            showError(settingsUnwritableMessage(path));
            return;
        }
        restrictPrivateDataFile(path);
        m_settingsError = false;
        m_errorBar->hide();
        m_error->clear();
        refreshIgnoredLabel();
    }

    void refreshIgnoredLabel() {
        if (!m_ignoredList) return;
        if (m_ignored.isEmpty()) {
            m_ignoredList->setText(
                QStringLiteral("None. Ignore a leftover from its inspector to hide it on later scans.")
            );
            m_clearIgnored->setEnabled(false);
            return;
        }
        QStringList names;
        for (const QString &p : m_ignored) names << ignoredPathLabel(p);
        names.sort();
        m_ignoredList->setText(
            QString::number(m_ignored.size()) + QStringLiteral(" leftover paths hidden from the list.\n")
            + names.mid(0, 12).join(QLatin1Char('\n'))
        );
        m_clearIgnored->setEnabled(true);
    }

    QListWidget *m_sidebar = nullptr;
    QStackedWidget *m_stack = nullptr;
    QWidget *m_overview = nullptr;
    QWidget *m_settings = nullptr;
    QTreeWidget *m_table = nullptr;
    QWidget *m_emptyPane = nullptr;
    QLabel *m_emptyTitle = nullptr;
    QLabel *m_emptyDetail = nullptr;
    QPushButton *m_clearSearch = nullptr;
    QPushButton *m_emptyRetry = nullptr;
    QWidget *m_errorBar = nullptr;
    QScrollArea *m_inspectorScroll = nullptr;
    QWidget *m_inspectorHost = nullptr;
    QVBoxLayout *m_inspectorLay = nullptr;
    QLabel *m_count = nullptr;
    QLabel *m_error = nullptr;
    QLineEdit *m_search = nullptr;
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
    QLabel *m_ignoredList = nullptr;
    QPushButton *m_clearIgnored = nullptr;
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
    QVector<Finding> m_findings;
    QSet<QString> m_marked;
    QSet<QString> m_markedManual;
    QSet<QString> m_ignored;
    QString m_selectedUid;
    QString m_scanAt;
    bool m_scanning = false;
    bool m_hasScanned = false;
    bool m_scanOk = false;
    bool m_confirmDelete = true;
    bool m_includeSystemOn = false;
    bool m_applyingAppearance = false;
    bool m_settingsError = false;
};

static bool argvHas(int argc, char **argv, const char *flag) {
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], flag) == 0) return true;
    }
    return false;
}

static int runHelp() {
    std::fprintf(stdout, "usage: appattic-qt [--version] [--help] [--smoke]\n");
    std::fprintf(stdout, "\n");
    std::fprintf(stdout, "  --version   print version and exit\n");
    std::fprintf(stdout, "  --help, -h  print this help and exit\n");
    std::fprintf(stdout, "  --smoke     headless smoke test and exit\n");
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
    if (ignoredPathLabel(QStringLiteral("/tmp/Caches/Foo")) != QLatin1String("Caches/Foo")) {
        std::fprintf(stderr, "ui-copy: ignored path label\n");
        return 1;
    }
    std::fprintf(stdout, "ui-copy: ok\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argvHas(argc, argv, "--help") || argvHas(argc, argv, "-h")) {
        return runHelp();
    }
    if (argvHas(argc, argv, "--version")) {
        return runVersion(argc, argv);
    }
    if (argvHas(argc, argv, "--smoke")) {
        const int timing = smokeTiming();
        if (timing != 0) return timing;
        const int rc = runSmoke(argc, argv);
        if (rc != 0) return rc;
        return smokeUiCopy();
    }
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("AppAttic"));
    QApplication::setOrganizationName(QStringLiteral("AppAttic"));
    MainWindow w;
    w.show();
    return app.exec();
}

#include "main.moc"
