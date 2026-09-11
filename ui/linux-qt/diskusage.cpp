#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "diskusage.h"

#include <QDateTime>
#include <QTimeZone>
#include <QDir>
#include <QByteArray>
#include <QFile>
#include <QFileInfo>
#include <QSet>
#include <QStorageInfo>
#include <QTemporaryDir>
#include <QVector>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

#ifdef Q_OS_UNIX
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#endif
#endif

namespace {

qint64 addSat(qint64 a, qint64 b) {
    if (b <= 0) return a;
    if (a > std::numeric_limits<qint64>::max() - b) return std::numeric_limits<qint64>::max();
    return a + b;
}

bool isCancelled(const DiskScanOptions &opts) {
    return opts.cancelled && opts.cancelled(opts.user);
}

struct InodeKey {
    quint64 dev = 0;
    quint64 ino = 0;
    bool operator==(const InodeKey &o) const { return dev == o.dev && ino == o.ino; }
};

struct InodeKeyHash {
    size_t operator()(const InodeKey &k) const {
        return size_t(k.dev) ^ (size_t(k.ino) << 1);
    }
};

struct WalkJob {
    DiskNode *node = nullptr;
    int fd = -1;
    std::string path;
};

struct WalkShared {
    quint64 rootDev = 0;
    const DiskScanOptions *opts = nullptr;
    std::atomic<qint64> dirs{0};
    std::mutex seenMu;
    std::unordered_set<InodeKey, InodeKeyHash> seen;
    std::mutex progressMu;
};

#ifdef Q_OS_UNIX
#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif
#ifndef AT_SYMLINK_NOFOLLOW
#define AT_SYMLINK_NOFOLLOW 0x100
#endif
#ifndef AT_NO_AUTOMOUNT
#define AT_NO_AUTOMOUNT 0x800
#endif

struct FileMeta {
    qint64 apparent = 0;
    qint64 allocated = 0;
    qint64 mtime = 0;
    quint64 dev = 0;
    quint64 ino = 0;
    quint64 nlink = 1;
    bool isDir = false;
    bool isLnk = false;
};

qint64 allocatedOf(uint64_t blocks) {
    return qint64(blocks) * 512;
}

bool metaFromStat(const struct stat &st, FileMeta *m) {
    m->apparent = qint64(st.st_size);
    m->allocated = allocatedOf(uint64_t(st.st_blocks));
    m->mtime = qint64(st.st_mtime);
    m->dev = quint64(st.st_dev);
    m->ino = quint64(st.st_ino);
    m->nlink = quint64(st.st_nlink);
    m->isLnk = S_ISLNK(st.st_mode);
    m->isDir = S_ISDIR(st.st_mode) && !m->isLnk;
    return true;
}

bool fillMetaFd(int fd, FileMeta *m) {
    struct stat st;
    if (fstat(fd, &st) != 0) return false;
    return metaFromStat(st, m);
}

bool fillMetaAt(int dirfd, const char *name, FileMeta *m) {
#ifdef __linux__
    struct statx stx;
    const unsigned mask = STATX_TYPE | STATX_MODE | STATX_NLINK | STATX_INO
        | STATX_SIZE | STATX_BLOCKS | STATX_MTIME;
    if (statx(dirfd, name, AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT, mask, &stx) == 0
        && (stx.stx_mask & STATX_TYPE) && (stx.stx_mask & STATX_INO)
        && (stx.stx_mask & STATX_SIZE) && (stx.stx_mask & STATX_BLOCKS)) {
        m->apparent = qint64(stx.stx_size);
        m->allocated = allocatedOf(uint64_t(stx.stx_blocks));
        m->mtime = (stx.stx_mask & STATX_MTIME) ? qint64(stx.stx_mtime.tv_sec) : 0;
        m->dev = quint64(makedev(stx.stx_dev_major, stx.stx_dev_minor));
        m->ino = quint64(stx.stx_ino);
        m->nlink = (stx.stx_mask & STATX_NLINK) ? quint64(stx.stx_nlink) : 1;
        m->isLnk = S_ISLNK(stx.stx_mode);
        m->isDir = S_ISDIR(stx.stx_mode) && !m->isLnk;
        return true;
    }
#endif
    struct stat st;
    if (fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) return false;
    return metaFromStat(st, m);
}

int openChildDir(int parentFd, const char *name) {
    return openat(parentFd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

bool pathPush(char *path, size_t *len, size_t cap, const char *name, size_t *saved) {
    *saved = *len;
    const size_t nlen = std::strlen(name);
    size_t need = nlen + 1;
    if (*len == 0 || path[*len - 1] != '/') need += 1;
    if (*len + need >= cap) return false;
    if (*len == 0 || path[*len - 1] != '/') path[(*len)++] = '/';
    std::memcpy(path + *len, name, nlen);
    *len += nlen;
    path[*len] = '\0';
    return true;
}

void pathPop(char *path, size_t *len, size_t saved) {
    *len = saved;
    path[saved] = '\0';
}

void addChildTotals(DiskNode *node, const DiskNode *child) {
    node->apparent = addSat(node->apparent, child->apparent);
    node->allocated = addSat(node->allocated, child->allocated);
    node->items = addSat(node->items, child->items);
}

void walkDirFd(
    DiskNode *node,
    int fd,
    char *path,
    size_t *pathLen,
    size_t pathCap,
    WalkShared *ctx,
    std::vector<WalkJob> *defer
);

void visitEntry(
    DiskNode *node,
    int dirfd,
    const char *name,
    char *path,
    size_t *pathLen,
    size_t pathCap,
    WalkShared *ctx,
    std::vector<WalkJob> *defer
) {
    if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) return;
    if (isCancelled(*ctx->opts)) return;
    FileMeta meta;
    if (!fillMetaAt(dirfd, name, &meta)) return;
    size_t saved = 0;
    if (!pathPush(path, pathLen, pathCap, name, &saved)) return;

    auto *child = new DiskNode;
    child->parent = node;
    child->name = QString::fromLocal8Bit(name);
    child->path = QString::fromLocal8Bit(path, int(*pathLen));
    child->mtime = meta.mtime;
    child->device = meta.dev;
    child->items = 1;
    child->isDir = meta.isDir;
    child->apparent = meta.apparent;
    const InodeKey key{meta.dev, meta.ino};
    bool seenDir = false;
    bool hardDup = false;
    bool deferDir = false;
    {
        std::lock_guard<std::mutex> lock(ctx->seenMu);
        seenDir = meta.isDir && ctx->seen.count(key);
        hardDup = !meta.isDir && meta.nlink > 1 && ctx->seen.count(key);
        if (!hardDup) {
            child->allocated = meta.allocated;
            if (!meta.isDir && meta.nlink > 1) ctx->seen.insert(key);
        }
        if (meta.isDir) {
            if (seenDir || (ctx->opts->oneFileSystem && meta.dev != ctx->rootDev)) {
                child->mountPoint = true;
            } else {
                ctx->seen.insert(key);
                deferDir = defer != nullptr;
            }
        }
    }
    if (meta.isDir && !child->mountPoint) {
        const int childFd = openChildDir(dirfd, name);
        if (childFd < 0) {
            child->unreadable = true;
            deferDir = false;
        } else if (deferDir) {
            WalkJob job;
            job.node = child;
            job.fd = childFd;
            job.path.assign(path, *pathLen);
            defer->push_back(job);
        } else {
            walkDirFd(child, childFd, path, pathLen, pathCap, ctx, nullptr);
            close(childFd);
        }
    }
    node->children.append(child);
    if (!deferDir) addChildTotals(node, child);
    pathPop(path, pathLen, saved);
}

#ifdef __linux__
struct AppDirent64 {
    uint64_t d_ino;
    int64_t d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[1];
};

void walkDirFd(
    DiskNode *node,
    int fd,
    char *path,
    size_t *pathLen,
    size_t pathCap,
    WalkShared *ctx,
    std::vector<WalkJob> *defer
) {
    if (isCancelled(*ctx->opts)) return;
    const qint64 dircount = ctx->dirs.fetch_add(1) + 1;
    if (ctx->opts->progress && (dircount % 64 == 0)) {
        std::lock_guard<std::mutex> lock(ctx->progressMu);
        ctx->opts->progress(dircount, node->path, ctx->opts->user);
    }
    alignas(8) char buf[16384];
    for (;;) {
        if (isCancelled(*ctx->opts)) return;
        const long nread = syscall(SYS_getdents64, fd, buf, sizeof buf);
        if (nread < 0) {
            if (errno == EINTR) continue;
            node->unreadable = true;
            return;
        }
        if (nread == 0) break;
        long bpos = 0;
        while (bpos < nread) {
            if (isCancelled(*ctx->opts)) return;
            auto *d = reinterpret_cast<AppDirent64 *>(buf + bpos);
            if (d->d_reclen < 19 || bpos + d->d_reclen > nread) break;
            bpos += d->d_reclen;
            visitEntry(node, fd, d->d_name, path, pathLen, pathCap, ctx, defer);
        }
    }
}
#else
void walkDirFd(
    DiskNode *node,
    int fd,
    char *path,
    size_t *pathLen,
    size_t pathCap,
    WalkShared *ctx,
    std::vector<WalkJob> *defer
) {
    if (isCancelled(*ctx->opts)) return;
    const int dupfd = dup(fd);
    if (dupfd < 0) {
        node->unreadable = true;
        return;
    }
    DIR *dir = fdopendir(dupfd);
    if (!dir) {
        close(dupfd);
        node->unreadable = true;
        return;
    }
    const qint64 dircount = ctx->dirs.fetch_add(1) + 1;
    if (ctx->opts->progress && (dircount % 64 == 0)) {
        std::lock_guard<std::mutex> lock(ctx->progressMu);
        ctx->opts->progress(dircount, node->path, ctx->opts->user);
    }
    while (dirent *ent = readdir(dir)) {
        if (isCancelled(*ctx->opts)) break;
        visitEntry(node, fd, ent->d_name, path, pathLen, pathCap, ctx, defer);
    }
    closedir(dir);
}
#endif

void measureWalkFd(
    int fd,
    quint64 rootDev,
    const DiskScanOptions &opts,
    std::unordered_set<InodeKey, InodeKeyHash> *seen,
    qint64 *apparent,
    qint64 *allocated
);

void measureVisit(
    int dirfd,
    const char *name,
    quint64 rootDev,
    const DiskScanOptions &opts,
    std::unordered_set<InodeKey, InodeKeyHash> *seen,
    qint64 *apparent,
    qint64 *allocated
) {
    if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) return;
    if (isCancelled(opts)) return;
    FileMeta meta;
    if (!fillMetaAt(dirfd, name, &meta)) return;
    const InodeKey key{meta.dev, meta.ino};
    const bool seenDir = meta.isDir && seen->count(key);
    const bool hardDup = !meta.isDir && meta.nlink > 1 && seen->count(key);
    if (!hardDup) {
        *allocated = addSat(*allocated, meta.allocated);
        if (!meta.isDir && meta.nlink > 1) seen->insert(key);
    }
    *apparent = addSat(*apparent, meta.apparent);
    if (!meta.isDir) return;
    if (seenDir || (opts.oneFileSystem && meta.dev != rootDev)) return;
    seen->insert(key);
    const int childFd = openChildDir(dirfd, name);
    if (childFd < 0) return;
    measureWalkFd(childFd, rootDev, opts, seen, apparent, allocated);
    close(childFd);
}

#ifdef __linux__
void measureWalkFd(
    int fd,
    quint64 rootDev,
    const DiskScanOptions &opts,
    std::unordered_set<InodeKey, InodeKeyHash> *seen,
    qint64 *apparent,
    qint64 *allocated
) {
    if (isCancelled(opts)) return;
    alignas(8) char buf[16384];
    for (;;) {
        if (isCancelled(opts)) return;
        const long nread = syscall(SYS_getdents64, fd, buf, sizeof buf);
        if (nread < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if (nread == 0) break;
        long bpos = 0;
        while (bpos < nread) {
            if (isCancelled(opts)) return;
            auto *d = reinterpret_cast<AppDirent64 *>(buf + bpos);
            if (d->d_reclen < 19 || bpos + d->d_reclen > nread) break;
            bpos += d->d_reclen;
            measureVisit(fd, d->d_name, rootDev, opts, seen, apparent, allocated);
        }
    }
}
#else
void measureWalkFd(
    int fd,
    quint64 rootDev,
    const DiskScanOptions &opts,
    std::unordered_set<InodeKey, InodeKeyHash> *seen,
    qint64 *apparent,
    qint64 *allocated
) {
    if (isCancelled(opts)) return;
    const int dupfd = dup(fd);
    if (dupfd < 0) return;
    DIR *dir = fdopendir(dupfd);
    if (!dir) {
        close(dupfd);
        return;
    }
    while (dirent *ent = readdir(dir)) {
        if (isCancelled(opts)) break;
        measureVisit(fd, ent->d_name, rootDev, opts, seen, apparent, allocated);
    }
    closedir(dir);
}
#endif
#endif

bool skipVolumeFs(const QString &fs) {
    const QString t = fs.toLower();
    static const char *kSkip[] = {
        "proc", "sysfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "securityfs",
        "pstore", "bpf", "tracefs", "debugfs", "hugetlbfs", "mqueue", "ramfs",
        "autofs", "fusectl", "configfs", "rpc_pipefs", "binfmt_misc", "overlay",
        "squashfs", "nsfs", "efivarfs", "tmpfs",
    };
    for (const char *s : kSkip) {
        if (t == QLatin1String(s)) return true;
    }
    return t.startsWith(QLatin1String("fuse.")) && t != QLatin1String("fuse.sshfs")
        && t != QLatin1String("fuse.rclone") && t != QLatin1String("fuse.gvfsd-fuse");
}

} // namespace

DiskNode::~DiskNode() {
    qDeleteAll(children);
    children.clear();
}

void DiskNode::sortChildren(bool allocatedSize) {
    std::sort(children.begin(), children.end(), [allocatedSize](const DiskNode *a, const DiskNode *b) {
        const qint64 as = a->metric(allocatedSize);
        const qint64 bs = b->metric(allocatedSize);
        if (as != bs) return as > bs;
        return a->name.compare(b->name, Qt::CaseInsensitive) < 0;
    });
    for (DiskNode *c : children) c->sortChildren(allocatedSize);
}

DiskNode *scanDiskTree(const QString &root, const DiskScanOptions &opts) {
    const QString path = QDir::cleanPath(root);
    auto *node = new DiskNode;
    node->name = QFileInfo(path).fileName();
    if (node->name.isEmpty()) node->name = path;
    node->path = path;
    node->isDir = true;
    node->items = 1;
#ifdef Q_OS_UNIX
    const QByteArray native = QFile::encodeName(path);
    const int fd = open(native.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) {
        node->unreadable = true;
        return node;
    }
    FileMeta meta;
    if (!fillMetaFd(fd, &meta) || !meta.isDir) {
        close(fd);
        node->unreadable = true;
        return node;
    }
    node->mtime = meta.mtime;
    node->device = meta.dev;
    node->apparent = meta.apparent;
    node->allocated = meta.allocated;
    char pathBuf[4096];
    const size_t nlen = size_t(native.size());
    if (nlen >= sizeof pathBuf) {
        close(fd);
        node->unreadable = true;
        return node;
    }
    std::memcpy(pathBuf, native.constData(), nlen);
    pathBuf[nlen] = '\0';
    size_t pathLen = nlen;
    WalkShared ctx;
    ctx.rootDev = meta.dev;
    ctx.opts = &opts;
    ctx.seen.insert(InodeKey{meta.dev, meta.ino});
    std::vector<WalkJob> jobs;
    walkDirFd(node, fd, pathBuf, &pathLen, sizeof pathBuf, &ctx, &jobs);
    close(fd);
    if (!jobs.empty()) {
        unsigned nworkers = std::thread::hardware_concurrency();
        if (nworkers == 0) nworkers = 2;
        if (nworkers > 8) nworkers = 8;
        if (nworkers > unsigned(jobs.size())) nworkers = unsigned(jobs.size());
        std::atomic<int> next{0};
        std::vector<std::thread> threads;
        threads.reserve(nworkers);
        for (unsigned t = 0; t < nworkers; t++) {
            threads.emplace_back([&ctx, &jobs, &next] {
                for (;;) {
                    const int i = next.fetch_add(1);
                    if (i >= int(jobs.size())) break;
                    if (isCancelled(*ctx.opts)) break;
                    WalkJob &job = jobs[size_t(i)];
                    char buf[4096];
                    const size_t n = job.path.size();
                    if (n >= sizeof buf) {
                        close(job.fd);
                        job.fd = -1;
                        continue;
                    }
                    std::memcpy(buf, job.path.data(), n);
                    buf[n] = '\0';
                    size_t len = n;
                    walkDirFd(job.node, job.fd, buf, &len, sizeof buf, &ctx, nullptr);
                    close(job.fd);
                    job.fd = -1;
                }
            });
        }
        for (std::thread &th : threads) th.join();
        for (WalkJob &job : jobs) {
            if (job.fd >= 0) {
                close(job.fd);
                job.fd = -1;
            }
            if (job.node && job.node->parent) addChildTotals(job.node->parent, job.node);
        }
    }
    node->sortChildren(true);
#else
    node->unreadable = true;
#endif
    return node;
}

qint64 measurePathBytes(const QString &path, const DiskScanOptions &opts) {
    const QString clean = QDir::cleanPath(path);
    if (clean.isEmpty()) return -1;
#ifdef Q_OS_UNIX
    const QByteArray native = QFile::encodeName(clean);
    FileMeta meta;
    if (!fillMetaAt(AT_FDCWD, native.constData(), &meta)) return -1;
    if (!meta.isDir) {
        if (meta.allocated > 0) return meta.allocated;
        return meta.apparent < 0 ? -1 : meta.apparent;
    }
    const int fd = open(native.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) {
        if (meta.allocated > 0) return meta.allocated;
        return meta.apparent < 0 ? 0 : meta.apparent;
    }
    FileMeta rootMeta;
    if (!fillMetaFd(fd, &rootMeta) || !rootMeta.isDir) {
        close(fd);
        if (meta.allocated > 0) return meta.allocated;
        return meta.apparent < 0 ? 0 : meta.apparent;
    }
    qint64 apparent = rootMeta.apparent;
    qint64 allocated = rootMeta.allocated;
    std::unordered_set<InodeKey, InodeKeyHash> seen;
    seen.insert(InodeKey{rootMeta.dev, rootMeta.ino});
    measureWalkFd(fd, rootMeta.dev, opts, &seen, &apparent, &allocated);
    close(fd);
    if (allocated > 0) return allocated;
    return apparent < 0 ? 0 : apparent;
#else
    const QFileInfo fi(clean);
    if (!fi.exists()) return -1;
    return qMax(qint64(0), fi.size());
#endif
}

QVector<DiskVolume> listDiskVolumes() {
    QVector<DiskVolume> out;
    const QString home = QDir::homePath();
    QSet<QString> seen;
    const QList<QStorageInfo> vols = QStorageInfo::mountedVolumes();
    for (const QStorageInfo &s : vols) {
        if (!s.isValid() || !s.isReady()) continue;
        const QString root = QDir::cleanPath(s.rootPath());
        if (root.isEmpty() || seen.contains(root)) continue;
        if (s.bytesTotal() <= 0) continue;
        if (root == QLatin1String("/run") || root.startsWith(QLatin1String("/run/"))
            || root == QLatin1String("/dev") || root.startsWith(QLatin1String("/dev/"))) {
            continue;
        }
        const QString fs = QString::fromUtf8(s.fileSystemType());
        if (skipVolumeFs(fs) && root != QLatin1String("/") && !home.startsWith(root)) continue;
        seen.insert(root);
        DiskVolume v;
        v.rootPath = root;
        v.device = QString::fromUtf8(s.device());
        v.fileSystem = fs;
        v.bytesTotal = s.bytesTotal();
        v.bytesFree = s.bytesFree();
        v.bytesAvailable = s.bytesAvailable();
        v.readOnly = s.isReadOnly();
        v.isRoot = root == QLatin1String("/");
        v.isHome = home == root || home.startsWith(root + QLatin1Char('/'));
        v.name = s.displayName();
        if (v.name.isEmpty() || v.name == root) {
            if (v.isRoot) v.name = QStringLiteral("File system");
            else v.name = QFileInfo(root).fileName();
            if (v.name.isEmpty()) v.name = root;
        }
        out.append(v);
    }
    std::sort(out.begin(), out.end(), [](const DiskVolume &a, const DiskVolume &b) {
        if (a.isRoot != b.isRoot) return a.isRoot;
        if (a.isHome != b.isHome) return a.isHome;
        return a.rootPath < b.rootPath;
    });
    return out;
}

QString diskContentsLabel(qint64 items, bool isDir) {
    if (!isDir) return QStringLiteral("1 file");
    if (items <= 1) return QStringLiteral("Empty");
    const qint64 n = items - 1;
    if (n == 1) return QStringLiteral("1 item");
    return QString::number(n) + QStringLiteral(" items");
}

QString diskModifiedLabel(qint64 mtime) {
    if (mtime <= 0) return QStringLiteral("-");
    const QDateTime dt = QDateTime::fromSecsSinceEpoch(mtime, QTimeZone::systemTimeZone());
    if (!dt.isValid()) return QStringLiteral("-");
    return dt.toString(QStringLiteral("yyyy-MM-dd"));
}

static int writeFile(const QString &path, const QByteArray &body) {
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return 1;
    if (f.write(body) != body.size()) return 1;
    return 0;
}

int smokeDiskUsage() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "disk: temp dir failed\n");
        return 1;
    }
    const QString root = tmp.path();
    const QString sub = root + QStringLiteral("/big");
    if (!QDir().mkpath(sub)) {
        std::fprintf(stderr, "disk: mkpath failed\n");
        return 1;
    }
    const QByteArray payload(4096, 'x');
    if (writeFile(sub + QStringLiteral("/a.bin"), payload)
        || writeFile(root + QStringLiteral("/small.txt"), QByteArray("hi\n"))) {
        std::fprintf(stderr, "disk: write failed\n");
        return 1;
    }
    const QString linkDir = root + QStringLiteral("/linkdir");
    if (!QFile::link(sub, linkDir)) {
        std::fprintf(stderr, "disk: symlink failed\n");
        return 1;
    }

    DiskScanOptions opts;
    opts.oneFileSystem = true;
    DiskNode *tree = scanDiskTree(root, opts);
    if (!tree || tree->unreadable || tree->children.size() < 2) {
        std::fprintf(stderr, "disk: scan produced no children\n");
        delete tree;
        return 1;
    }
    const DiskNode *big = nullptr;
    const DiskNode *small = nullptr;
    const DiskNode *link = nullptr;
    for (const DiskNode *c : tree->children) {
        if (c->name == QLatin1String("big")) big = c;
        if (c->name == QLatin1String("small.txt")) small = c;
        if (c->name == QLatin1String("linkdir")) link = c;
    }
    if (!big || !big->isDir || big->apparent < 4096) {
        std::fprintf(stderr, "disk: big dir apparent size missing\n");
        delete tree;
        return 1;
    }
    if (!small || small->isDir || small->apparent < 3) {
        std::fprintf(stderr, "disk: small file missing\n");
        delete tree;
        return 1;
    }
    if (measurePathBytes(sub) < 4096) {
        std::fprintf(stderr, "disk: measurePathBytes missed the 4096-byte file\n");
        delete tree;
        return 1;
    }
    if (!link || link->isDir) {
        std::fprintf(stderr, "disk: directory symlink was followed\n");
        delete tree;
        return 1;
    }
    if (tree->apparent < big->apparent || tree->items < 3) {
        std::fprintf(stderr, "disk: root totals too small\n");
        delete tree;
        return 1;
    }
    tree->sortChildren(false);
    if (tree->children.isEmpty() || tree->children[0]->name != QLatin1String("big")) {
        std::fprintf(stderr, "disk: sort by apparent did not put big first\n");
        delete tree;
        return 1;
    }
    delete tree;
    tree = nullptr;

    const QString many = root + QStringLiteral("/many");
    if (!QDir().mkpath(many)) {
        std::fprintf(stderr, "disk: many mkpath failed\n");
        return 1;
    }
    for (int i = 0; i < 200; ++i) {
        const QString n = QStringLiteral("%1/f%2.txt").arg(many).arg(i);
        if (writeFile(n, QByteArray("x\n"))) {
            std::fprintf(stderr, "disk: many write failed\n");
            return 1;
        }
    }
    tree = scanDiskTree(root, opts);
    if (!tree || tree->unreadable) {
        std::fprintf(stderr, "disk: rescan after many files failed\n");
        delete tree;
        return 1;
    }
    const DiskNode *manyNode = nullptr;
    for (const DiskNode *c : tree->children) {
        if (c->name == QLatin1String("many")) manyNode = c;
    }
    if (!manyNode || !manyNode->isDir || manyNode->children.size() < 200) {
        std::fprintf(stderr, "disk: getdents listing missed files (%d)\n",
            manyNode ? int(manyNode->children.size()) : -1);
        delete tree;
        return 1;
    }
    const QString linkRoot = root + QStringLiteral("/rootlink");
    if (!QFile::link(sub, linkRoot)) {
        std::fprintf(stderr, "disk: root symlink failed\n");
        delete tree;
        return 1;
    }
    delete tree;
    tree = scanDiskTree(linkRoot, opts);
    if (!tree || tree->unreadable || tree->children.isEmpty()) {
        std::fprintf(stderr, "disk: scan of directory symlink root failed\n");
        delete tree;
        return 1;
    }
    bool sawBin = false;
    for (const DiskNode *c : tree->children) {
        if (c->name == QLatin1String("a.bin")) sawBin = true;
    }
    if (!sawBin) {
        std::fprintf(stderr, "disk: symlink root did not follow to contents\n");
        delete tree;
        return 1;
    }
    delete tree;

    const QVector<DiskVolume> vols = listDiskVolumes();
    bool hasRoot = false;
    for (const DiskVolume &v : vols) {
        if (v.isRoot && v.bytesTotal > 0) hasRoot = true;
        if (v.rootPath == QLatin1String("/proc")) {
            std::fprintf(stderr, "disk: listed virtual /proc\n");
            return 1;
        }
        if (v.fileSystem.toLower() == QLatin1String("tmpfs")
            && v.rootPath != QLatin1String("/")
            && !v.isHome) {
            std::fprintf(stderr, "disk: listed tmpfs %s\n", v.rootPath.toUtf8().constData());
            return 1;
        }
        if (v.rootPath == QLatin1String("/run")
            || v.rootPath.startsWith(QLatin1String("/run/"))) {
            std::fprintf(stderr, "disk: listed /run mount %s\n", v.rootPath.toUtf8().constData());
            return 1;
        }
    }
    if (!hasRoot) {
        std::fprintf(stderr, "disk: file system volume missing\n");
        return 1;
    }
    if (diskContentsLabel(1, true) != QLatin1String("Empty")) {
        std::fprintf(stderr, "disk: empty contents label\n");
        return 1;
    }
    if (diskContentsLabel(5, true) != QLatin1String("4 items")) {
        std::fprintf(stderr, "disk: items label\n");
        return 1;
    }
    std::fprintf(stdout, "disk: ok\n");
    return 0;
}
