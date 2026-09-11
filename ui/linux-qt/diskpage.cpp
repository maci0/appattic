#include "diskpage.h"

#include "diskchart.h"
#include "diskusage.h"
#include "finding.h"
#include "uistyle.h"

#include <QAction>
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
#include <QStorageInfo>
#include <QThread>
#include <QTimer>
#include <QToolBar>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QUrl>
#include <QVBoxLayout>

#include <utility>

static QTreeWidgetItem *makeItem(DiskNode *n);
static void appendChildren(QTreeWidgetItem *parent, DiskNode *node, int depth);

class DiskScanWorker : public QObject {
    Q_OBJECT
public:
    void setWanted(int token) { m_wanted.storeRelease(token); }
    void requestCancel() { m_wanted.storeRelease(0); }
    bool isCancelled() const { return m_wanted.loadAcquire() != m_token; }
    DiskNode *takeRoot() {
        DiskNode *r = m_root;
        m_root = nullptr;
        return r;
    }

public slots:
    void run(const QString &path, bool oneFs, int token) {
        m_token = token;
        delete m_root;
        m_root = nullptr;
        DiskScanOptions opts;
        opts.oneFileSystem = oneFs;
        opts.user = this;
        opts.cancelled = [](void *user) -> bool {
            return static_cast<DiskScanWorker *>(user)->isCancelled();
        };
        opts.progress = [](qint64 dirs, const QString &p, void *user) {
            emit static_cast<DiskScanWorker *>(user)->progress(dirs, p);
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
    void progress(qint64 dirs, const QString &path);
    void finished(int token);
    void scanStopped(int token);

private:
    DiskNode *m_root = nullptr;
    QAtomicInteger<int> m_wanted{0};
    int m_token = 0;
};

class DiskPage::Impl {
public:
    DiskPage *q = nullptr;
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
    QThread *thread = nullptr;
    DiskScanWorker *worker = nullptr;
    DiskNode *root = nullptr;
    DiskNode *selected = nullptr;
    QString scanPath;
    QString filter;
    bool allocated = true;
    int scanToken = 0;

    DiskNode *nodeFromItem(QTreeWidgetItem *it) const {
        if (!it) return nullptr;
        return static_cast<DiskNode *>(it->data(0, Qt::UserRole).value<void *>());
    }
};

DiskPage::DiskPage(QWidget *parent) : QWidget(parent), d(new Impl) {
    d->q = this;
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
        QStringLiteral("Scan a folder or storage device.")
    );
    intro->setWordWrap(true);
    intro->setFont(aaSmallFont());
    intro->setForegroundRole(QPalette::PlaceholderText);
    intro->setContentsMargins(16, 12, 16, 8);
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
    homeBtn->setToolTip(QStringLiteral("Scan your home folder"));
    folderBtn->setToolTip(QStringLiteral("Scan a local folder, including FUSE or network mounts"));
    fsBtn->setToolTip(QStringLiteral("Scan the root file system without crossing into other devices"));
    remoteBtn->setToolTip(QStringLiteral("Scan a mounted network folder (sshfs, SMB, gvfs)"));
    scanBar->addWidget(homeBtn);
    scanBar->addWidget(folderBtn);
    scanBar->addWidget(fsBtn);
    scanBar->addWidget(remoteBtn);
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
    d->volumes->header()->setSectionResizeMode(0, QHeaderView::Stretch);
    d->volumes->header()->setSectionResizeMode(1, QHeaderView::Stretch);
    for (int c = 2; c < 6; ++c) {
        d->volumes->header()->setSectionResizeMode(c, QHeaderView::ResizeToContents);
    }
    d->volumes->header()->setHighlightSections(false);
    d->volumes->setFrameShape(QFrame::NoFrame);
    d->volumes->setTextElideMode(Qt::ElideRight);
    if (QTreeWidgetItem *head = d->volumes->headerItem()) {
        for (int c = 3; c <= 5; ++c) {
            head->setTextAlignment(c, Qt::AlignRight | Qt::AlignVCenter);
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
    d->crumb->setContentsMargins(8, 0, 8, 0);
    d->stopBtn = new QPushButton(QStringLiteral("Stop"));
    d->rescanBtn = new QPushButton(QStringLiteral("Rescan"));
    d->upBtn = new QPushButton(QStringLiteral("Up"));
    d->openBtn = new QPushButton(QStringLiteral("Open"));
    d->trashBtn = new QPushButton(QStringLiteral("Move to Trash"));
    d->chartMode = new QComboBox;
    d->chartMode->addItem(QStringLiteral("Rings"), int(DiskChart::Mode::Rings));
    d->chartMode->addItem(QStringLiteral("Treemap"), int(DiskChart::Mode::Treemap));
    d->sizeMode = new QComboBox;
    d->sizeMode->addItem(QStringLiteral("Allocated"), 1);
    d->sizeMode->addItem(QStringLiteral("Apparent"), 0);
    d->oneFs = new QCheckBox(QStringLiteral("This file system only"));
    d->oneFs->setChecked(true);
    d->search = new QLineEdit;
    d->search->setPlaceholderText(QStringLiteral("Search"));
    d->search->setClearButtonEnabled(true);
    d->search->setFixedWidth(180);
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
    ph->setContentsMargins(16, 0, 16, 8);
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
        head->setTextAlignment(1, Qt::AlignRight | Qt::AlignVCenter);
        head->setTextAlignment(2, Qt::AlignRight | Qt::AlignVCenter);
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
    d->status->setContentsMargins(16, 6, 16, 6);
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
    connect(d->volumes, &QTreeWidget::itemActivated, this, [this](QTreeWidgetItem *it, int) {
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
        if (n && n->isDir) {
            d->chart->setView(n);
            updateChrome();
        }
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
    connect(d->worker, &DiskScanWorker::progress, this, [this](qint64 dirs, const QString &path) {
        const QString label = QString::number(dirs)
            + QStringLiteral(" folders · ")
            + path;
        d->progressLabel->setText(label);
        d->status->setText(label);
        emit statusMessage(QStringLiteral("Scanning disk usage · ") + label);
    });
    connect(d->worker, &DiskScanWorker::finished, this, [this](int token) {
        if (token != d->scanToken) return;
        DiskNode *tree = d->worker->takeRoot();
        m_scanning = false;
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
        emit statusMessage(QStringLiteral("Disk scan stopped"));
    });

    auto *volTimer = new QTimer(this);
    volTimer->setInterval(5000);
    connect(volTimer, &QTimer::timeout, this, [this] {
        if (d->stack->currentWidget() == d->locations && !m_scanning) refreshVolumes();
    });
    volTimer->start();
    refreshVolumes();
    updateChrome();
}

DiskPage::~DiskPage() {
    if (d->worker) d->worker->requestCancel();
    if (d->thread) {
        d->thread->quit();
        d->thread->wait();
    }
    d->chart->setRoot(nullptr);
    d->tree->clear();
    delete d->root;
    delete d->worker;
    delete d;
}

void DiskPage::setSearch(const QString &text) {
    d->search->setText(text);
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
    QString gvfs = QString::fromLocal8Bit(qgetenv("XDG_RUNTIME_DIR")) + QStringLiteral("/gvfs");
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
        const qint64 used = v.bytesTotal > v.bytesFree ? v.bytesTotal - v.bytesFree : 0;
        it->setText(4, humanSize(used));
        it->setText(5, humanSize(v.bytesAvailable));
        it->setData(1, Qt::UserRole, v.rootPath);
        it->setToolTip(1, v.device);
        const QFont nums = aaNumericFont();
        it->setFont(3, nums);
        it->setFont(4, nums);
        it->setFont(5, nums);
        it->setTextAlignment(3, Qt::AlignRight | Qt::AlignVCenter);
        it->setTextAlignment(4, Qt::AlignRight | Qt::AlignVCenter);
        it->setTextAlignment(5, Qt::AlignRight | Qt::AlignVCenter);
    }
    for (int i = 0; i < 6; ++i) d->volumes->resizeColumnToContents(i);
}

void DiskPage::startScan(const QString &path) {
    if (path.isEmpty()) return;
    d->scanToken += 1;
    d->worker->setWanted(d->scanToken);
    d->scanPath = path;
    m_scanning = true;
    showScan();
    d->progress->show();
    d->progressLabel->show();
    d->progressLabel->setText(path);
    d->status->setText(QStringLiteral("Scanning ") + path);
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
    emit statusMessage(QStringLiteral("Scanning disk usage · ") + path);
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

void DiskPage::showLocations() {
    d->stack->setCurrentWidget(d->locations);
    refreshVolumes();
}

void DiskPage::showScan() { d->stack->setCurrentWidget(d->scanPage); }

static QTreeWidgetItem *makeItem(DiskNode *n) {
    auto *it = new QTreeWidgetItem;
    QString name = n->name;
    if (n->unreadable) name += QStringLiteral(" (unreadable)");
    if (n->mountPoint) name += QStringLiteral(" (other file system)");
    it->setText(0, name);
    it->setText(1, humanSize(n->apparent));
    it->setText(2, humanSize(n->allocated));
    it->setText(3, diskContentsLabel(n->items, n->isDir));
    it->setText(4, diskModifiedLabel(n->mtime));
    it->setData(0, Qt::UserRole, QVariant::fromValue(static_cast<void *>(n)));
    it->setToolTip(0, n->path);
    const QFont nums = aaNumericFont();
    it->setFont(1, nums);
    it->setFont(2, nums);
    it->setTextAlignment(1, Qt::AlignRight | Qt::AlignVCenter);
    it->setTextAlignment(2, Qt::AlignRight | Qt::AlignVCenter);
    const QColor dim = QApplication::palette().color(QPalette::PlaceholderText);
    it->setForeground(3, dim);
    it->setForeground(4, dim);
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
    const QString q = d->filter.trimmed();
    if (q.isEmpty()) {
        fillTree();
        return;
    }
    const auto walk = [&](auto &&self, DiskNode *n) -> void {
        if (n->name.contains(q, Qt::CaseInsensitive) || n->path.contains(q, Qt::CaseInsensitive)) {
            d->tree->addTopLevelItem(makeItem(n));
        }
        for (DiskNode *ch : n->children) self(self, ch);
    };
    walk(walk, d->root);
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
    rescan();
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
    DiskNode *view = d->chart->viewRoot();
    d->upBtn->setEnabled(!scanning && view && view->parent);
    d->openBtn->setEnabled(d->selected);
    d->trashBtn->setEnabled(!scanning && d->selected && d->selected != d->root);
    d->crumb->setText(view ? view->path : (d->scanPath.isEmpty() ? QStringLiteral("Devices") : d->scanPath));
    if (d->root && !scanning) {
        d->status->setText(
            humanSize(d->root->metric(d->allocated))
            + QStringLiteral(" · ")
            + diskContentsLabel(d->root->items, true)
            + (d->root->unreadable ? QStringLiteral(" · some folders could not be read") : QString())
        );
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
