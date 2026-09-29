#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "diskusage.h"

#include "finding.h"

#include <QCollator>
#include <QDateTime>
#include <QTimeZone>
#include <QDir>
#include <QLocale>
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
#include <cstddef>
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
// The statx() wrapper and its STATX_* constants reach <sys/stat.h> in glibc
// 2.28, so on an older glibc the call and the struct do not exist to compile
// against. The fstatat fallback in fillMetaAt is what every Linux already has,
// so the statx path is gated on the declarations being there and nothing else.
#if defined(STATX_BLOCKS) && (!defined(__GLIBC__) || __GLIBC_PREREQ(2, 28))
#define APPATTIC_HAVE_STATX 1
#endif
#endif
#endif

qint64 addSatBytes(qint64 a, qint64 b) {
    // A negative running total means "not measured", not a debt, so a measured
    // addend starts the sum over rather than cancelling into it.
    if (a < 0) a = 0;
    if (b <= 0) return a;
    if (a > std::numeric_limits<qint64>::max() - b) return std::numeric_limits<qint64>::max();
    return a + b;
}

namespace {

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

/// Bytes per st_blocks unit: POSIX fixes the block count at 512-byte units on
/// every platform this scans. A spec constant, not a tunable.
constexpr qint64 kBytesPerBlock = 512;

qint64 allocatedOf(uint64_t blocks) {
    // Saturating multiply, like every other byte total here. Signed overflow is
    // undefined and the scan would keep a wrapped negative size in the tree.
    if (blocks > uint64_t(std::numeric_limits<qint64>::max() / kBytesPerBlock))
        return std::numeric_limits<qint64>::max();
    return qint64(blocks) * kBytesPerBlock;
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
#ifdef APPATTIC_HAVE_STATX
    // statx needs Linux 4.11 for AT_NO_AUTOMOUNT; the kernel side is probed
    // through stx_mask and the call falling through to fstatat below, which
    // every Linux has.
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

/// A deferred directory is held open until the worker phase starts, so the
/// first-thread walk would otherwise sit on one descriptor per directory it
/// found. Past this many outstanding fds a child is walked inline and closed at
/// once, which keeps the walk off the descriptor limit on a wide tree.
constexpr size_t kMaxDeferredDirFds = 64;

void addChildTotals(DiskNode *node, const DiskNode *child) {
    node->apparent = addSatBytes(node->apparent, child->apparent);
    node->allocated = addSatBytes(node->allocated, child->allocated);
    node->items = addSatBytes(node->items, child->items);
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
    // Bytes from readdir/statfs, not locale text: decode as UTF-8 like every
    // other core boundary here. Under a C locale `fromLocal8Bit` reads them as
    // Latin-1, so a "Café" name displays as "CafÃ©" and the mangled path then
    // names a file that does not exist. A name with undecodable bytes becomes
    // U+FFFD, which is visible, instead of silent Latin-1 garbage.
    child->name = QString::fromUtf8(name);
    child->path = QString::fromUtf8(path, int(*pathLen));
    child->mtime = meta.mtime;
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
    if (deferDir && defer->size() >= kMaxDeferredDirFds) deferDir = false;
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
/// The kernel's `struct linux_dirent64`, the record getdents64 writes. Only
/// its field offsets are used: records start at arbitrary offsets in the
/// buffer, so casting the buffer to this type would dereference a misaligned
/// pointer, which is undefined behavior and traps on strict-alignment targets.
struct AppDirent64 {
    uint64_t d_ino;
    int64_t d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[1];
};

constexpr size_t kDirent64NameOffset = offsetof(AppDirent64, d_name);
/// Shortest record that can carry a name and its terminator.
constexpr unsigned kDirent64MinRecLen =
    static_cast<unsigned>(kDirent64NameOffset) + 2;

/// reclen and name of the record at `pos`, read without assuming alignment.
struct Dirent64View {
    unsigned short reclen;
    const char *name;
};

// Whether a whole record header fits at `pos`. The check has to precede the
// read: `nread` can leave fewer than the header's bytes when a caller is
// handed a truncated trailing record.
inline bool dirent64Fits(long nread, long pos) {
    return pos >= 0 && pos <= nread
        && nread - pos >= static_cast<long>(kDirent64MinRecLen);
}

inline Dirent64View viewDirent64(const char *buf, long pos) {
    unsigned short reclen = 0;
    memcpy(&reclen, buf + pos + offsetof(AppDirent64, d_reclen), sizeof reclen);
    return Dirent64View{reclen, buf + pos + kDirent64NameOffset};
}

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
            if (!dirent64Fits(nread, bpos)) break;
            const Dirent64View d = viewDirent64(buf, bpos);
            if (d.reclen < kDirent64MinRecLen || bpos + d.reclen > nread) break;
            bpos += d.reclen;
            visitEntry(node, fd, d.name, path, pathLen, pathCap, ctx, defer);
        }
    }
    if (ctx->opts->dirDone) ctx->opts->dirDone(*node, ctx->opts->user);
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
    const qint64 dircount = ctx->dirs.fetch_add(1) + 1;
    if (ctx->opts->progress && (dircount % 64 == 0)) {
        std::lock_guard<std::mutex> lock(ctx->progressMu);
        ctx->opts->progress(dircount, node->path, ctx->opts->user);
    }
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
    // `errno` is cleared per call, not once before the loop: `visitEntry`
    // runs fstatat/openat, which set errno on ordinary events (an entry that
    // vanished mid-scan, a directory this process may not open). Clearing it
    // only up front would report a directory read in full as unreadable
    // because of the last failure inside it.
    for (;;) {
        errno = 0;
        struct dirent *ent = readdir(dir);
        if (!ent) break;
        if (isCancelled(*ctx->opts)) break;
        visitEntry(node, fd, ent->d_name, path, pathLen, pathCap, ctx, defer);
    }
    if (errno != 0) node->unreadable = true;
    closedir(dir);
    if (ctx->opts->dirDone) ctx->opts->dirDone(*node, ctx->opts->user);
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
        *allocated = addSatBytes(*allocated, meta.allocated);
        if (!meta.isDir && meta.nlink > 1) seen->insert(key);
    }
    *apparent = addSatBytes(*apparent, meta.apparent);
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
            if (!dirent64Fits(nread, bpos)) break;
            const Dirent64View d = viewDirent64(buf, bpos);
            if (d.reclen < kDirent64MinRecLen || bpos + d.reclen > nread) break;
            bpos += d.reclen;
            measureVisit(fd, d.name, rootDev, opts, seen, apparent, allocated);
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
    // Collation, not code units: `QString::compare(..., Qt::CaseInsensitive)`
    // orders by code unit, so "Zebra" sorts before "apple" and "Ä" lands after
    // "Z" in German or Swedish. `QCollator` holds the locale's rules; the C
    // locale has none, so it keeps the code-unit order. The collator is built
    // once for the whole tree: opening an ICU collator costs far more than the
    // comparisons, and this recurses into every directory.
    const QLocale locale;
    const bool collated = locale.name() != QLatin1String("C");
    const QCollator collator(locale);
    sortChildrenWith(allocatedSize, collated, &collator);
}

void DiskNode::sortChildrenWith(bool allocatedSize, bool collated, const QCollator *collator) {
    std::sort(children.begin(), children.end(), [allocatedSize, collated, collator](const DiskNode *a, const DiskNode *b) {
        const qint64 as = a->metric(allocatedSize);
        const qint64 bs = b->metric(allocatedSize);
        if (as != bs) return as > bs;
        if (collated) {
            const int c = collator->compare(a->name, b->name);
            if (c != 0) return c < 0;
        } else {
            const int c = a->name.compare(b->name, Qt::CaseInsensitive);
            if (c != 0) return c < 0;
        }
        // `std::sort` is not stable, so rows the collator calls equal would keep
        // the order the directory walk handed over, which the filesystem picks
        // and changes between runs.
        return a->path < b->path;
    });
    for (DiskNode *c : children) c->sortChildrenWith(allocatedSize, collated, collator);
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
        v.bytesAvailable = s.bytesAvailable();
        v.isRoot = root == QLatin1String("/");
        // "/" + "/" is "//", which no path starts with, so the root volume
        // has to be compared on its own. Matches listDiskVolumes in
        // Sources/AppAtticScan/DiskUsage.swift.
        v.isHome = home == root
            || (v.isRoot ? home.startsWith(QLatin1Char('/'))
                         : home.startsWith(root + QLatin1Char('/')));
        v.name = s.displayName();
        if (v.name.isEmpty() || v.name == root) {
            if (v.isRoot) v.name = QStringLiteral("File system");
            else v.name = QFileInfo(root).fileName();
            if (v.name.isEmpty()) v.name = root;
        }
        out.append(v);
    }
    // Collation, not code units: `QString` orders by UTF-16 code unit, so a
    // mount point with a non-ASCII name ("/media/Ünïcode", "/Volumes/日本語")
    // lands after every ASCII one. `QCollator` holds the locale's rules; the C
    // locale has none, so it keeps the code-unit order. Same order the macOS
    // window prints, from listDiskVolumes in AppAtticScan/DiskUsage.swift.
    const QLocale locale;
    const bool collated = locale.name() != QLatin1String("C");
    const QCollator collator(locale);
    std::sort(out.begin(), out.end(), [collated, &collator](const DiskVolume &a, const DiskVolume &b) {
        if (a.isRoot != b.isRoot) return a.isRoot;
        if (a.isHome != b.isHome) return a.isHome;
        if (collated) return collator.compare(a.rootPath, b.rootPath) < 0;
        return a.rootPath < b.rootPath;
    });
    return out;
}

qint64 volumeUsedBytes(qint64 total, qint64 available) {
    if (total <= 0 || available >= total) return 0;
    if (available < 0) return total;
    return total - available;
}

QString diskContentsLabel(qint64 items, bool isDir) {
    if (!isDir) return QStringLiteral("1 file");
    if (items <= 1) return QStringLiteral("Empty");
    const qint64 n = items - 1;
    if (n == 1) return QStringLiteral("1 item");
    return localeCount(n) + QStringLiteral(" items");
}

QString diskModifiedLabel(qint64 mtime) {
    if (mtime <= 0) return QStringLiteral("unknown");
    const QDateTime dt = QDateTime::fromSecsSinceEpoch(mtime, QTimeZone::systemTimeZone());
    if (!dt.isValid()) return QStringLiteral("unknown");
    return localeDateLabel(dt.date());
}


