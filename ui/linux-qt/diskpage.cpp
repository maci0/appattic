#include "diskpage.h"

#include "diskchart.h"
#include "diskusage.h"
#include "finding.h"
#include "uistyle.h"

#include <QApplication>
#include <QAtomicInteger>
#include <QCheckBox>
#include <QClipboard>
#include <QComboBox>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFrame>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QMessageBox>
#include <QProgressBar>
#include <QPushButton>
#include <QSizePolicy>
#include <QSplitter>
#include <QStackedWidget>
#include <QThread>
#include <QTimer>
#include <QToolBar>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QUrl>
#include <QVBoxLayout>

#include <utility>

static QTreeWidgetItem *makeItem(DiskNode *n);
static QTreeWidgetItem *makeValueItem(
    const QString &name,
    const QString &path,
    qint64 apparent,
    qint64 allocated,
    qint64 items,
    qint64 mtime,
    bool isDir,
    bool unreadable,
    bool mountPoint
);
static void appendChildren(QTreeWidgetItem *parent, DiskNode *node, int depth);

/// How long the destructor waits for the scan thread before detaching it. The
/// walk tests the cancel flag between directories, so a normal stop returns at
/// once; a getdents64 on a hung network mount does not come back at all, and an
/// unbounded wait would freeze the GUI at quit.
static constexpr int kScanThreadDrainMs = 8000;

class DiskScanWorker : public QObject {
    Q_OBJECT
public:
    void setWanted(int token) { m_wanted.storeRelease(token); }
    void requestCancel() { m_wanted.storeRelease(0); }
    bool isCancelled() const { return m_wanted.loadAcquire() != m_token.loadAcquire(); }
    DiskNode *takeRoot() {
        DiskNode *r = m_root;
        m_root = nullptr;
        return r;
    }
    /* A scan that finished after the page stopped listening for it (the page
       was destroyed, so the queued `finished` never ran) leaves its tree here,
       and the page's own delete never sees it. */
    ~DiskScanWorker() override { delete m_root; }

public slots:
    void run(const QString &path, bool oneFs, int token) {
        m_token.storeRelease(token);
        delete m_root;
        m_root = nullptr;
        DiskScanOptions opts;
        opts.oneFileSystem = oneFs;
        opts.user = this;
        opts.cancelled = [](void *user) -> bool {
            return static_cast<DiskScanWorker *>(user)->isCancelled();
        };
        opts.progress = [](qint64 dirs, const QString &p, void *user) {
            auto *w = static_cast<DiskScanWorker *>(user);
            emit w->progress(w->m_token.loadAcquire(), dirs, p);
        };
        opts.dirDone = [](const DiskNode &n, void *user) {
            auto *w = static_cast<DiskScanWorker *>(user);
            emit w->dirDone(
                w->m_token.loadAcquire(),
                n.path,
                n.name,
                n.apparent,
                n.allocated,
                n.items,
                n.mtime
            );
        };
        if (isCancelled()) {
            emit scanStopped(token);
            return;
        }
        m_root = scanDiskTree(path, opts);
        if (isCancelled()) {
            delete m_root;
            m_root = nullptr;
            emit scanStopped(token);
            return;
        }
        emit finished(token);
    }

signals:
    /// `token` is the run that produced the event, not the one the page is
    /// showing. A rescan can start before a cancelled walk has drained, and the
    /// events of the old run are already sitting in the queue behind it.
    void progress(int token, qint64 dirs, const QString &path);
    /// One finished directory, as values: the tree it came from is owned by the
    /// scanning thread. Built-in types only, so the signal needs no metatype.
    void dirDone(
        int token,
        const QString &path,
        const QString &name,
        qint64 apparent,
        qint64 allocated,
        qint64 items,
        qint64 mtime
    );
    void finished(int token);
    void scanStopped(int token);

private:
    DiskNode *m_root = nullptr;
    QAtomicInteger<int> m_wanted{0};
    /// Read from the walk's worker threads on every cancellation check and on
    /// every streamed event, so it is atomic like the token it is compared to.
    QAtomicInteger<int> m_token{0};
};

class DiskPage::Impl {
public:
    QStackedWidget *stack = nullptr;
    QWidget *locations = nullptr;
    QWidget *scanPage = nullptr;
    QTreeWidget *volumes = nullptr;
    QTreeWidget *tree = nullptr;
    DiskChart *chart = nullptr;
    QLabel *crumb = nullptr;
    QLabel *status = nullptr;
    QLabel *progressLabel = nullptr;
    QProgressBar *progress = nullptr;
    QPushButton *stopBtn = nullptr;
    QPushButton *rescanBtn = nullptr;
    QPushButton *upBtn = nullptr;
    QPushButton *openBtn = nullptr;
    QPushButton *trashBtn = nullptr;
    QComboBox *chartMode = nullptr;
    QComboBox *sizeMode = nullptr;
    QCheckBox *oneFs = nullptr;
    QLineEdit *search = nullptr;
    QPushButton *devicesBtn = nullptr;
    QPushButton *backBtn = nullptr;
    QThread *thread = nullptr;
    DiskScanWorker *worker = nullptr;
    DiskNode *root = nullptr;
    DiskNode *selected = nullptr;
    QString scanPath;
    QString filter;
    bool allocated = true;
    int scanToken = 0;
    int streamedRows = 0;
    bool streamedBeforeFinish = false;
    /// -1 while the tree is unfiltered, else the number of search matches. Drives
    /// the "no folders match" status so a blank tree always has an explanation.
    int filterMatches = -1;
    /// The ring chart paints from a DiskNode tree, and the real one only exists
    /// when the walk ends, so the page keeps its own from the folders that have
    /// finished. Freed with `delete`, which takes the children.
    DiskNode *streamRoot = nullptr;
    int streamedSegments = 0;

    /// Frees the placeholder tree; the segment count stays for the gate.
    void dropStreamRoot() {
        delete streamRoot;
        streamRoot = nullptr;
    }

    DiskNode *nodeFromItem(QTreeWidgetItem *it) const {
        if (!it) return nullptr;
        return static_cast<DiskNode *>(it->data(0, Qt::UserRole).value<void *>());
    }
};

DiskPage::DiskPage(QWidget *parent) : QWidget(parent), d(new Impl) {
    auto *lay = new QVBoxLayout(this);
    lay->setContentsMargins(0, 0, 0, 0);
    lay->setSpacing(0);
    d->stack = new QStackedWidget;
    lay->addWidget(d->stack, 1);

    d->locations = new QWidget;
    auto *lv = new QVBoxLayout(d->locations);
    lv->setContentsMargins(0, 0, 0, 0);
    lv->setSpacing(0);
    auto *intro = new QLabel(
        QStringLiteral("Scan a folder or storage device. Double-click a row to scan it.")
    );
    intro->setWordWrap(true);
    intro->setFont(aaSmallFont());
    intro->setForegroundRole(QPalette::PlaceholderText);
    intro->setContentsMargins(kSpaceLg, kSpaceMd, kSpaceLg, kSpaceSm);
    lv->addWidget(intro);
    auto *scanBar = new QToolBar;
    scanBar->setMovable(false);
    scanBar->setFloatable(false);
    scanBar->setIconSize(QSize(16, 16));
    scanBar->setToolButtonStyle(Qt::ToolButtonTextOnly);
    scanBar->setContextMenuPolicy(Qt::PreventContextMenu);
    auto *homeBtn = new QPushButton(QStringLiteral("Scan Home"));
    auto *folderBtn = new QPushButton(QStringLiteral("Scan Folder"));
    auto *fsBtn = new QPushButton(QStringLiteral("Scan File System"));
    auto *remoteBtn = new QPushButton(QStringLiteral("Scan Remote"));
    d->backBtn = new QPushButton(QStringLiteral("Back"));
    d->backBtn->setToolTip(QStringLiteral("Return to the disk scan in progress"));
    homeBtn->setToolTip(QStringLiteral("Scan your home folder"));
    folderBtn->setToolTip(QStringLiteral("Scan a local folder, including FUSE or network mounts"));
    fsBtn->setToolTip(QStringLiteral("Scan the root file system without crossing into other devices"));
    remoteBtn->setToolTip(QStringLiteral("Scan a mounted network folder (sshfs, SMB, gvfs)"));
    scanBar->addWidget(homeBtn);
    scanBar->addWidget(folderBtn);
    scanBar->addWidget(fsBtn);
    scanBar->addWidget(remoteBtn);
    scanBar->addWidget(d->backBtn);
    lv->addWidget(scanBar);
    d->volumes = new QTreeWidget;
    d->volumes->setColumnCount(6);
    d->volumes->setHeaderLabels({
        QStringLiteral("Name"),
        QStringLiteral("Location"),
        QStringLiteral("Type"),
        QStringLiteral("Size"),
        QStringLiteral("Used"),
        QStringLiteral("Available"),
    });
    d->volumes->setRootIsDecorated(false);
    d->volumes->setUniformRowHeights(true);
    d->volumes->setSelectionMode(QAbstractItemView::SingleSelection);
    d->volumes->header()->setStretchLastSection(false);
    // Name takes the slack, like the overview panels: stretching Location too
    // left a wide hole between the two.
    d->volumes->header()->setSectionResizeMode(0, QHeaderView::Stretch);
    d->volumes->header()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
    for (int c = 2; c < 6; ++c) {
        d->volumes->header()->setSectionResizeMode(c, QHeaderView::ResizeToContents);
    }
    d->volumes->header()->setHighlightSections(false);
    d->volumes->setFrameShape(QFrame::NoFrame);
    d->volumes->setTextElideMode(Qt::ElideRight);
    if (QTreeWidgetItem *head = d->volumes->headerItem()) {
        for (int c = 3; c <= 5; ++c) {
            head->setTextAlignment(c, Qt::AlignTrailing | Qt::AlignVCenter);
        }
    }
    lv->addWidget(d->volumes, 1);
    d->stack->addWidget(d->locations);

    d->scanPage = new QWidget;
    auto *sv = new QVBoxLayout(d->scanPage);
    sv->setContentsMargins(0, 0, 0, 0);
    sv->setSpacing(0);
    auto *tools = new QToolBar;
    tools->setMovable(false);
    tools->setFloatable(false);
    tools->setIconSize(QSize(16, 16));
    tools->setToolButtonStyle(Qt::ToolButtonTextOnly);
    tools->setContextMenuPolicy(Qt::PreventContextMenu);
    d->crumb = new QLabel;
    d->crumb->setTextInteractionFlags(Qt::TextSelectableByMouse);
    d->crumb->setContentsMargins(kSpaceSm, 0, kSpaceSm, 0);
    d->devicesBtn = new QPushButton(QStringLiteral("Devices"));
    d->devicesBtn->setToolTip(QStringLiteral("Back to the device and folder list"));
    d->stopBtn = new QPushButton(QStringLiteral("Stop"));
    d->rescanBtn = new QPushButton(QStringLiteral("Rescan"));
    d->upBtn = new QPushButton(QStringLiteral("Up"));
    d->openBtn = new QPushButton(QStringLiteral("Open"));
    d->trashBtn = new QPushButton(QStringLiteral("Move to Trash"));
    d->chartMode = new QComboBox;
    d->chartMode->setToolTip(QStringLiteral("How the size chart draws the folders"));
    d->chartMode->addItem(QStringLiteral("Rings"), int(DiskChart::Mode::Rings));
    d->chartMode->addItem(QStringLiteral("Treemap"), int(DiskChart::Mode::Treemap));
    d->sizeMode = new QComboBox;
    d->sizeMode->setToolTip(
        QStringLiteral("Allocated counts blocks on disk; apparent counts file lengths")
    );
    d->sizeMode->addItem(QStringLiteral("Allocated"), 1);
    d->sizeMode->addItem(QStringLiteral("Apparent"), 0);
    d->oneFs = new QCheckBox(QStringLiteral("This file system only"));
    d->oneFs->setChecked(true);
    // The two mode pickers beside it redraw the tree as they change; this one
    // only sets what the next walk does, so say so instead of letting the
    // toggle look broken.
    d->oneFs->setToolTip(
        QStringLiteral("Sets what the next scan reads. Press Rescan to scan again with it.")
    );
    d->search = new QLineEdit;
    d->search->setPlaceholderText(QStringLiteral("Search"));
    d->search->setClearButtonEnabled(true);
    d->search->setFixedWidth(180);
    d->search->setToolTip(QStringLiteral("Filter the scanned folders by name or path"));
    tools->addWidget(d->devicesBtn);
    tools->addWidget(d->crumb);
    auto *diskSpacer = new QWidget;
    diskSpacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    tools->addWidget(diskSpacer);
    tools->addWidget(d->stopBtn);
    tools->addWidget(d->rescanBtn);
    tools->addWidget(d->upBtn);
    tools->addWidget(d->openBtn);
    tools->addWidget(d->trashBtn);
    tools->addWidget(d->chartMode);
    tools->addWidget(d->sizeMode);
    tools->addWidget(d->oneFs);
    tools->addWidget(d->search);
    sv->addWidget(tools);
    auto *prog = new QWidget;
    auto *ph = new QHBoxLayout(prog);
    ph->setContentsMargins(kSpaceLg, 0, kSpaceLg, kSpaceSm);
    d->progress = new QProgressBar;
    d->progress->setRange(0, 0);
    d->progress->setTextVisible(false);
    d->progress->setMaximumHeight(6);
    d->progressLabel = new QLabel;
    d->progressLabel->setFont(aaSmallFont());
    d->progressLabel->setForegroundRole(QPalette::PlaceholderText);
    ph->addWidget(d->progress, 1);
    ph->addWidget(d->progressLabel, 2);
    sv->addWidget(prog);
    d->progress->hide();
    d->progressLabel->hide();

    auto *split = new QSplitter(Qt::Horizontal);
    split->setHandleWidth(1);
    d->tree = new QTreeWidget;
    d->tree->setColumnCount(5);
    d->tree->setHeaderLabels({
        QStringLiteral("Name"),
        QStringLiteral("Size"),
        QStringLiteral("Allocated"),
        QStringLiteral("Contents"),
        QStringLiteral("Modified"),
    });
    d->tree->setUniformRowHeights(true);
    d->tree->setSelectionMode(QAbstractItemView::SingleSelection);
    d->tree->header()->setStretchLastSection(true);
    d->tree->header()->setHighlightSections(false);
    d->tree->setFrameShape(QFrame::NoFrame);
    d->tree->setTextElideMode(Qt::ElideRight);
    d->tree->setContextMenuPolicy(Qt::CustomContextMenu);
    if (QTreeWidgetItem *head = d->tree->headerItem()) {
        head->setTextAlignment(1, Qt::AlignTrailing | Qt::AlignVCenter);
        head->setTextAlignment(2, Qt::AlignTrailing | Qt::AlignVCenter);
    }
    d->chart = new DiskChart;
    split->addWidget(d->tree);
    split->addWidget(d->chart);
    split->setStretchFactor(0, 1);
    split->setStretchFactor(1, 1);
    split->setSizes({520, 420});
    sv->addWidget(split, 1);
    d->status = new QLabel;
    d->status->setFont(aaSmallFont());
    d->status->setContentsMargins(kSpaceLg, kSpaceSm, kSpaceLg, kSpaceSm);
    d->status->setForegroundRole(QPalette::PlaceholderText);
    sv->addWidget(d->status);
    d->stack->addWidget(d->scanPage);

    d->thread = new QThread(this);
    d->worker = new DiskScanWorker;
    d->worker->moveToThread(d->thread);
    d->thread->start();

    connect(homeBtn, &QPushButton::clicked, this, &DiskPage::scanHome);
    connect(folderBtn, &QPushButton::clicked, this, &DiskPage::scanFolder);
    connect(fsBtn, &QPushButton::clicked, this, &DiskPage::scanFilesystem);
    connect(remoteBtn, &QPushButton::clicked, this, &DiskPage::scanRemote);
    connect(d->backBtn, &QPushButton::clicked, this, [this] { showScan(); });
    connect(d->devicesBtn, &QPushButton::clicked, this, [this] { showLocations(); });
    connect(d->volumes, &QTreeWidget::itemActivated, this, [this](QTreeWidgetItem *it, int) {
        if (!it) return;
        startScan(it->data(1, Qt::UserRole).toString());
    });
    // A double click is what the rest of the app drills in with, and the intro
    // line now promises it. Enter alone was the only way in before.
    connect(d->volumes, &QTreeWidget::itemDoubleClicked, this, [this](QTreeWidgetItem *it, int) {
        if (!it) return;
        startScan(it->data(1, Qt::UserRole).toString());
    });
    connect(d->stopBtn, &QPushButton::clicked, this, [this] { stopScan(); });
    connect(d->rescanBtn, &QPushButton::clicked, this, [this] { rescan(); });
    connect(d->upBtn, &QPushButton::clicked, this, [this] { goUp(); });
    connect(d->openBtn, &QPushButton::clicked, this, [this] { openSelected(); });
    connect(d->trashBtn, &QPushButton::clicked, this, [this] { trashSelected(); });
    connect(d->chartMode, &QComboBox::currentIndexChanged, this, [this] {
        d->chart->setMode(DiskChart::Mode(d->chartMode->currentData().toInt()));
    });
    connect(d->sizeMode, &QComboBox::currentIndexChanged, this, [this] {
        d->allocated = d->sizeMode->currentData().toInt() != 0;
        if (d->root) d->root->sortChildren(d->allocated);
        d->chart->setAllocated(d->allocated);
        fillTree();
    });
    connect(d->search, &QLineEdit::textChanged, this, [this](const QString &t) {
        d->filter = t;
        fillTreeFiltered();
    });
    connect(d->tree, &QTreeWidget::currentItemChanged, this, [this](QTreeWidgetItem *it, QTreeWidgetItem *) {
        selectNode(d->nodeFromItem(it));
    });
    connect(d->tree, &QTreeWidget::itemExpanded, this, [this](QTreeWidgetItem *it) {
        DiskNode *n = d->nodeFromItem(it);
        if (!n || it->childCount() > 0) return;
        appendChildren(it, n, 10);
    });
    connect(d->tree, &QTreeWidget::itemDoubleClicked, this, [this](QTreeWidgetItem *it, int) {
        DiskNode *n = d->nodeFromItem(it);
        if (!n || !n->isDir) return;
        // The crumb, the chart and the tree have to name the same folder: the
        // single click already moved the view, so without the refill the tree
        // kept listing the parent while the breadcrumb read as the child, and
        // "Up" then jumped the tree to a view it had never shown.
        d->chart->setView(n);
        d->selected = n;
        fillTree();
        updateChrome();
    });
    connect(d->tree, &QTreeWidget::customContextMenuRequested, this, [this](const QPoint &pos) {
        QTreeWidgetItem *it = d->tree->itemAt(pos);
        if (it) d->tree->setCurrentItem(it);
        QMenu m(d->tree);
        m.addAction(QStringLiteral("Open"), this, [this] { openSelected(); });
        m.addAction(QStringLiteral("Copy path"), this, [this] { copyPath(); });
        m.addAction(QStringLiteral("Move to Trash"), this, [this] { trashSelected(); });
        if (d->selected && d->selected->isDir) {
            m.addAction(QStringLiteral("Scan this folder"), this, [this] {
                if (d->selected) startScan(d->selected->path);
            });
        }
        m.exec(d->tree->mapToGlobal(pos));
    });
    connect(d->chart, &DiskChart::nodeActivated, this, [this](DiskNode *n) {
        selectNode(n);
        updateChrome();
    });
    connect(d->worker, &DiskScanWorker::progress, this, [this](int token, qint64 dirs, const QString &path) {
        if (token != d->scanToken) return;
        // The scanned path is under the account home, so it carries the
        // account name. The status text is what leaves the window (status bar,
        // screenshot), so it names the folder as `~/...`; the tree keeps the
        // full path where the user asked for it.
        const QString label = localeCount(dirs)
            + QStringLiteral(" folders · ")
            + redactHomePaths(path);
        d->progressLabel->setText(label);
        d->status->setText(label);
        emit statusMessage(QStringLiteral("Scanning disk usage · ") + label);
    });
    connect(d->worker, &DiskScanWorker::dirDone, this,
            [this](int token, const QString &path, const QString &name, qint64 apparent,
                   qint64 allocated, qint64 items, qint64 mtime) {
                if (token != d->scanToken) return;
                if (!m_scanning || d->root) return;
                // Only the rows the finished tree shows directly under the root.
                const int slash = path.lastIndexOf(QLatin1Char('/'));
                const QString parent = slash > 0 ? path.left(slash) : QStringLiteral("/");
                if (parent != d->scanPath) return;
                QTreeWidgetItem *top = d->tree->topLevelItem(0);
                if (!top) {
                    QString label = QFileInfo(d->scanPath).fileName();
                    if (label.isEmpty()) label = d->scanPath;
                    top = new QTreeWidgetItem(d->tree);
                    top->setText(0, label);
                    top->setToolTip(0, d->scanPath);
                    top->setExpanded(true);
                }
                QTreeWidgetItem *item = makeValueItem(
                    name, path, apparent, allocated, items, mtime, true, false, false
                );
                item->setFont(1, aaNumericFont());
                item->setFont(2, aaNumericFont());
                item->setTextAlignment(1, Qt::AlignTrailing | Qt::AlignVCenter);
                item->setTextAlignment(2, Qt::AlignTrailing | Qt::AlignVCenter);
                item->setData(1, Qt::UserRole, apparent);
                item->setData(2, Qt::UserRole, allocated);
                item->setData(3, Qt::UserRole, items);
                // Inserted by apparent size, the column the tree sorts on by
                // default. The ring chart below sorts on the selected metric,
                // so its order can differ from the streaming rows.
                int at = top->childCount();
                for (int i = 0; i < top->childCount(); ++i) {
                    if (apparent > top->child(i)->data(1, Qt::UserRole).toLongLong()) {
                        at = i;
                        break;
                    }
                }
                top->insertChild(at, item);
                d->streamedRows += 1;
                qint64 sumApparent = 0;
                qint64 sumAllocated = 0;
                qint64 sumItems = 0;
                for (int i = 0; i < top->childCount(); ++i) {
                    sumApparent = addSatBytes(sumApparent, top->child(i)->data(1, Qt::UserRole).toLongLong());
                    sumAllocated = addSatBytes(sumAllocated, top->child(i)->data(2, Qt::UserRole).toLongLong());
                    sumItems = addSatBytes(sumItems, top->child(i)->data(3, Qt::UserRole).toLongLong());
                }
                // Placeholder root row: the totals of what has arrived so far.
                // `diskContentsLabel` counts the node itself, and the walk
                // counts the scan root as one entry, so the streamed total
                // needs that one: without it a folder whose first finished
                // child has arrived reads "Empty" until the scan ends.
                top->setText(1, humanSize(sumApparent));
                top->setText(2, humanSize(sumAllocated));
                top->setText(3, diskContentsLabel(sumItems + 1, true));
                // Ring chart: one segment per finished folder, live.
                if (!d->streamRoot) {
                    d->streamRoot = new DiskNode;
                    QString label = QFileInfo(d->scanPath).fileName();
                    if (label.isEmpty()) label = d->scanPath;
                    d->streamRoot->name = label;
                    d->streamRoot->path = d->scanPath;
                    d->streamRoot->isDir = true;
                }
                DiskNode *kid = nullptr;
                for (DiskNode *existing : d->streamRoot->children) {
                    if (existing->path == path) {
                        kid = existing;
                        break;
                    }
                }
                if (!kid) {
                    kid = new DiskNode;
                    kid->path = path;
                    kid->isDir = true;
                    d->streamRoot->children.append(kid);
                }
                kid->name = name;
                kid->apparent = apparent;
                kid->allocated = allocated;
                kid->items = items;
                kid->mtime = mtime;
                d->streamRoot->apparent = sumApparent;
                d->streamRoot->allocated = sumAllocated;
                d->streamRoot->sortChildren(d->allocated);
                d->streamedSegments = d->streamRoot->children.size();
                d->chart->setRoot(d->streamRoot);
                updateChrome();
            });
    connect(d->worker, &DiskScanWorker::finished, this, [this](int token) {
        if (token != d->scanToken) return;
        DiskNode *tree = d->worker->takeRoot();
        m_scanning = false;
        d->streamedBeforeFinish = d->streamedRows > 0;
        d->dropStreamRoot();
        d->chart->setRoot(nullptr);
        d->tree->clear();
        delete d->root;
        d->root = tree;
        d->selected = d->root;
        d->progress->hide();
        d->progressLabel->hide();
        d->chart->setRoot(d->root);
        fillTree();
        updateChrome();
        emit statusMessage(QStringLiteral("Disk scan finished"));
    });
    connect(d->worker, &DiskScanWorker::scanStopped, this, [this](int token) {
        if (token != d->scanToken) return;
        m_scanning = false;
        d->progress->hide();
        d->progressLabel->hide();
        updateChrome();
        // The rows the walk had finished are still on screen, and a blank line
        // under them reads as an empty scan rather than a cancelled one.
        d->status->setText(
            d->streamedRows > 0
                ? QStringLiteral("Scan stopped. %1 folders measured so far.").arg(
                    localeCount(d->streamedRows)
                )
                : QStringLiteral("Scan stopped before any folder finished.")
        );
        emit statusMessage(QStringLiteral("Disk scan stopped"));
    });

    auto *volTimer = new QTimer(this);
    volTimer->setInterval(5000);
    connect(volTimer, &QTimer::timeout, this, [this] {
        if (d->stack->currentWidget() == d->locations && !m_scanning) refreshVolumes();
    });
    volTimer->start();
    // Sets the Back button's first state too: hidden until a scan exists.
    showLocations();
    updateChrome();
}

DiskPage::~DiskPage() {
    if (d->worker) d->worker->requestCancel();
    bool stopped = true;
    if (d->thread) {
        d->thread->quit();
        stopped = d->thread->wait(kScanThreadDrainMs);
    }
    if (!stopped) {
        /* The scan thread still owns its tree and the worker it is running on.
           Deleting either from here would free a tree under the walk, and
           ~QObject would delete a running QThread, so both are detached and
           left to the process exit. */
        d->thread->setParent(nullptr);
        delete d;
        return;
    }
    d->chart->setRoot(nullptr);
    d->tree->clear();
    delete d->root;
    // A scan stopped before it finished keeps its placeholder chart tree, and
    // the next scan is the only other thing that drops it.
    d->dropStreamRoot();
    delete d->worker;
    delete d;
}

void DiskPage::scanHome() { startScan(QDir::homePath()); }

void DiskPage::scanFolder() {
    const QString path = QFileDialog::getExistingDirectory(
        this,
        QStringLiteral("Scan folder"),
        QDir::homePath()
    );
    if (!path.isEmpty()) startScan(path);
}

void DiskPage::scanFilesystem() { startScan(QStringLiteral("/")); }

void DiskPage::scanRemote() {
    QString gvfs = QString::fromUtf8(qgetenv("XDG_RUNTIME_DIR")) + QStringLiteral("/gvfs");
    if (gvfs.startsWith(QLatin1Char('/')) == false) {
        gvfs = QDir::homePath() + QStringLiteral("/.gvfs");
    }
    QString start = QDir::homePath();
    if (QDir(gvfs).exists()) start = gvfs;
    else if (QDir(QStringLiteral("/mnt")).exists()) start = QStringLiteral("/mnt");
    const QString path = QFileDialog::getExistingDirectory(
        this,
        QStringLiteral("Scan mounted network folder"),
        start
    );
    if (!path.isEmpty()) startScan(path);
}

void DiskPage::refreshVolumes() {
    d->volumes->clear();
    const QVector<DiskVolume> vols = listDiskVolumes();
    for (const DiskVolume &v : vols) {
        auto *it = new QTreeWidgetItem(d->volumes);
        QString name = v.name;
        if (v.isHome && !v.isRoot) name += QStringLiteral(" (Home)");
        it->setText(0, name);
        it->setText(1, v.rootPath);
        it->setText(2, v.fileSystem);
        it->setText(3, humanSize(v.bytesTotal));
        const qint64 used = volumeUsedBytes(v.bytesTotal, v.bytesAvailable);
        it->setText(4, humanSize(used));
        it->setText(5, humanSize(v.bytesAvailable));
        it->setData(1, Qt::UserRole, v.rootPath);
        it->setToolTip(1, v.device);
        const QFont nums = aaNumericFont();
        it->setFont(3, nums);
        it->setFont(4, nums);
        it->setFont(5, nums);
        it->setTextAlignment(3, Qt::AlignTrailing | Qt::AlignVCenter);
        it->setTextAlignment(4, Qt::AlignTrailing | Qt::AlignVCenter);
        it->setTextAlignment(5, Qt::AlignTrailing | Qt::AlignVCenter);
    }
    for (int i = 0; i < 6; ++i) d->volumes->resizeColumnToContents(i);
}

void DiskPage::startScan(const QString &path) {
    if (path.isEmpty()) return;
    d->scanToken += 1;
    d->worker->setWanted(d->scanToken);
    d->scanPath = path;
    m_scanning = true;
    d->streamedRows = 0;
    d->streamedSegments = 0;
    d->streamedBeforeFinish = false;
    d->dropStreamRoot();
    showScan();
    d->progress->show();
    d->progressLabel->show();
    d->progressLabel->setText(redactHomePaths(path));
    d->status->setText(QStringLiteral("Scanning ") + redactHomePaths(path));
    d->chart->setRoot(nullptr);
    d->tree->clear();
    d->selected = nullptr;
    delete d->root;
    d->root = nullptr;
    updateChrome();
    const bool one = d->oneFs->isChecked();
    QMetaObject::invokeMethod(
        d->worker,
        "run",
        Qt::QueuedConnection,
        Q_ARG(QString, path),
        Q_ARG(bool, one),
        Q_ARG(int, d->scanToken)
    );
    emit statusMessage(QStringLiteral("Scanning disk usage · ") + redactHomePaths(path));
}

void DiskPage::stopScan() {
    if (!m_scanning) return;
    d->worker->requestCancel();
}

void DiskPage::rescan() {
    if (d->scanPath.isEmpty()) {
        showLocations();
        return;
    }
    startScan(d->scanPath);
}

void DiskPage::showEvent(QShowEvent *event) {
    QWidget::showEvent(event);
    d->backBtn->setVisible(!d->scanPath.isEmpty() && d->stack->currentWidget() == d->locations);
}

void DiskPage::showLocations() {
    d->stack->setCurrentWidget(d->locations);
    // Only offer the way back once there is a scan to return to, so the button
    // never sits there as a dead control on a first visit.
    d->backBtn->setVisible(!d->scanPath.isEmpty());
    refreshVolumes();
}

void DiskPage::showScan() {
    d->stack->setCurrentWidget(d->scanPage);
    d->backBtn->setVisible(true);
}

/// A row built from values alone: the streaming path cannot touch the
/// DiskNode, which the scanning thread owns. The `unreadable` and
/// `mountPoint` flags are false while a scan streams, so a folder that is a
/// mount point or came back unreadable loses that suffix until the finished
/// tree redraws it.
static QTreeWidgetItem *makeValueItem(
    const QString &name,
    const QString &path,
    qint64 apparent,
    qint64 allocated,
    qint64 items,
    qint64 mtime,
    bool isDir,
    bool unreadable,
    bool mountPoint
) {
    auto *it = new QTreeWidgetItem;
    QString label = name;
    if (unreadable) label += QStringLiteral(" (unreadable)");
    if (mountPoint) label += QStringLiteral(" (other file system)");
    it->setText(0, label);
    it->setText(1, humanSize(apparent));
    it->setText(2, humanSize(allocated));
    it->setText(3, diskContentsLabel(items, isDir));
    it->setText(4, diskModifiedLabel(mtime));
    it->setToolTip(0, path);
    const QFont nums = aaNumericFont();
    it->setFont(1, nums);
    it->setFont(2, nums);
    it->setTextAlignment(1, Qt::AlignTrailing | Qt::AlignVCenter);
    it->setTextAlignment(2, Qt::AlignTrailing | Qt::AlignVCenter);
    const QColor dim = QApplication::palette().color(QPalette::PlaceholderText);
    it->setForeground(3, dim);
    it->setForeground(4, dim);
    return it;
}

static QTreeWidgetItem *makeItem(DiskNode *n) {
    QTreeWidgetItem *it = makeValueItem(
        n->name,
        n->path,
        n->apparent,
        n->allocated,
        n->items,
        n->mtime,
        n->isDir,
        n->unreadable,
        n->mountPoint
    );
    it->setData(0, Qt::UserRole, QVariant::fromValue(static_cast<void *>(n)));
    return it;
}

static void appendChildren(QTreeWidgetItem *parent, DiskNode *node, int depth) {
    if (depth > 12) return;
    for (DiskNode *ch : node->children) {
        QTreeWidgetItem *it = makeItem(ch);
        parent->addChild(it);
        if (ch->isDir && !ch->children.isEmpty() && depth < 3) {
            appendChildren(it, ch, depth + 1);
        } else if (ch->isDir && !ch->children.isEmpty()) {
            it->setChildIndicatorPolicy(QTreeWidgetItem::ShowIndicator);
        }
    }
}

void DiskPage::fillTree() {
    d->tree->clear();
    d->filterMatches = -1;
    if (!d->root) return;
    if (!d->filter.trimmed().isEmpty()) {
        fillTreeFiltered();
        return;
    }
    DiskNode *view = d->chart->viewRoot() ? d->chart->viewRoot() : d->root;
    QTreeWidgetItem *top = makeItem(view);
    d->tree->addTopLevelItem(top);
    appendChildren(top, view, 0);
    top->setExpanded(true);
    d->tree->setCurrentItem(top);
    for (int i = 0; i < 5; ++i) d->tree->resizeColumnToContents(i);
}

void DiskPage::fillTreeFiltered() {
    d->tree->clear();
    if (!d->root) return;
    const QString q = searchFold(d->filter.trimmed());
    if (q.isEmpty()) {
        fillTree();
        return;
    }
    int matches = 0;
    const auto walk = [&](auto &&self, DiskNode *n) -> void {
        // `searchFold` on both sides, like the findings tables: a name off an
        // exFAT/NTFS/SMB mount arrives decomposed ("cafe" + U+0301) while the
        // search box gives the precomposed keystroke, and a raw
        // `contains(..., CaseInsensitive)` compares code units, so the row the
        // user typed a word for disappears.
        if (searchFold(n->name).contains(q) || searchFold(n->path).contains(q)) {
            d->tree->addTopLevelItem(makeItem(n));
            matches += 1;
        }
        for (DiskNode *ch : n->children) self(self, ch);
    };
    walk(walk, d->root);
    d->filterMatches = matches;
    updateChrome();
}

void DiskPage::selectNode(DiskNode *node) {
    d->selected = node;
    if (node && node->isDir) d->chart->setView(node);
    updateChrome();
}

void DiskPage::openSelected() {
    DiskNode *n = d->selected;
    if (!n) return;
    QString path = n->path;
    if (!n->isDir) path = QFileInfo(path).absolutePath();
    QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

void DiskPage::copyPath() {
    if (!d->selected) return;
    QApplication::clipboard()->setText(d->selected->path);
    // The other two menu items say what they did. This one was silent, so a
    // paste that came out empty had nothing to explain it.
    emit statusMessage(
        QStringLiteral("Copied %1 to the clipboard.").arg(redactHomePaths(d->selected->path))
    );
}

void DiskPage::trashSelected() {
    if (!d->selected || d->selected == d->root) return;
    const QString path = d->selected->path;
    const QString msg = QStringLiteral("Move “%1” to Trash?").arg(d->selected->name);
    if (QMessageBox::question(this, QStringLiteral("Move to Trash"), msg)
        != QMessageBox::Yes) {
        return;
    }
    if (!QFile::moveToTrash(path)) {
        QMessageBox::warning(
            this,
            QStringLiteral("Move to Trash"),
            QStringLiteral("Could not move %1 to Trash.").arg(path)
        );
        return;
    }
    // Without this the window only says it is scanning again, and a user who
    // answered the alert has no confirmation the folder was trashed. It goes
    // out after the rescan, whose own "Scanning" message would replace it.
    const QString trashed = d->selected->name;
    rescan();
    emit statusMessage(QStringLiteral("Moved %1 to Trash. Scanning again…").arg(trashed));
}

void DiskPage::goUp() {
    d->chart->goUp();
    DiskNode *view = d->chart->viewRoot();
    d->selected = view;
    fillTree();
    updateChrome();
}

void DiskPage::updateChrome() {
    const bool scanning = m_scanning;
    d->stopBtn->setEnabled(scanning);
    d->rescanBtn->setEnabled(!scanning && !d->scanPath.isEmpty());
    // Same busy state as the other scan controls: the walk reads this at its
    // start, so changing it mid-scan would promise something the run ignores.
    d->oneFs->setEnabled(!scanning);
    DiskNode *view = d->chart->viewRoot();
    d->upBtn->setEnabled(!scanning && view && view->parent);
    d->openBtn->setEnabled(d->selected);
    d->trashBtn->setEnabled(!scanning && d->selected && d->selected != d->root);
    d->crumb->setText(view ? view->path : (d->scanPath.isEmpty() ? QStringLiteral("Devices") : d->scanPath));
    if (d->root && !scanning) {
        if (d->filterMatches >= 0) {
            // A filtered tree must not read as the whole scan, and an empty
            // result must not read as a broken one.
            d->status->setText(
                d->filterMatches == 0
                    ? QStringLiteral("No folders match “%1”.").arg(d->filter.trimmed())
                    : QStringLiteral("%1 folders match “%2”.")
                          .arg(localeCount(d->filterMatches))
                          .arg(d->filter.trimmed())
            );
        } else {
            d->status->setText(
                humanSize(d->root->metric(d->allocated))
                + QStringLiteral(" · ")
                + diskContentsLabel(d->root->items, true)
                + (d->root->unreadable ? QStringLiteral(" · some folders could not be read") : QString())
            );
        }
    } else if (scanning) {
        if (d->status->text().isEmpty() || d->status->text() == QLatin1String("Scanning")) {
            d->status->setText(
                d->scanPath.isEmpty()
                    ? QStringLiteral("Scanning disk usage")
                    : QStringLiteral("Scanning ") + d->scanPath
            );
        }
    } else {
        d->status->setText(QString());
    }
}

#include "diskpage.moc"

int DiskPage::streamedRows() const { return d->streamedRows; }

int DiskPage::streamedSegments() const { return d->streamedSegments; }

bool DiskPage::streamedBeforeFinish() const { return d->streamedBeforeFinish; }
