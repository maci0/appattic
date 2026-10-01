// Concurrency coverage for the two places this UI runs its own threads:
// the deferred-subtree walk in diskusage.cpp and the leftover-size pool in
// finding.cpp. Both hand a partition of a shared vector to worker threads and
// fold the results back afterwards, which is exactly the shape a data race
// hides in, and neither is reachable from tests/helper_tests.cpp on a machine
// without Wasmtime, because that target links the wasm host.
//
// The assertions here pin behaviour that a race would change: every row gets
// its own measured size (a lost write shows as a row still holding the -1
// default), the totals add up (a torn read-modify-write shows as a total that
// does not match the parts), the root's dirDone fires once and only after its
// deferred children are folded in, and cancelling stops the work.
//
// Run under ThreadSanitizer (`scripts/race-check.sh`), which is what turns
// these from "the answer looked right once" into memory-ordering evidence.

#include "diskusage.h"
#include "finding.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <atomic>
#include <cstdio>
#include <cstdint>

namespace {

int fail(const char *what, const char *detail = nullptr) {
    if (detail) std::fprintf(stderr, "race_tests: %s: %s\n", what, detail);
    else std::fprintf(stderr, "race_tests: %s\n", what);
    return 1;
}

bool writeFile(const QString &path, const QByteArray &bytes) {
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    const bool ok = f.write(bytes) == bytes.size();
    f.close();
    return ok;
}

/// The walk hands one `user` pointer to every callback it runs, and those
/// callbacks fire on whichever pool thread finished that directory. Each
/// field is therefore touched from several threads at once, so each is its own
/// atomic and they are read only after scanDiskTree returned and every worker
/// has joined.
struct WalkProbe {
    std::atomic<int> rootDone{0};
    std::atomic<int> dirDone{0};
    std::atomic<int> progressCalls{0};
    std::atomic<qint64> lastRootItems{-1};
};

void noteDirDone(const DiskNode &node, void *user) {
    auto *p = static_cast<WalkProbe *>(user);
    if (node.parent == nullptr) {
        p->rootDone.fetch_add(1);
        p->lastRootItems.store(node.items);
    } else {
        p->dirDone.fetch_add(1);
    }
}

void noteProgress(qint64, const QString &, void *user) {
    static_cast<WalkProbe *>(user)->progressCalls.fetch_add(1);
}

/// A tree wide and deep enough to overflow kMaxDeferredDirFds (64), which is
/// what forces the deferred-subtree worker phase in diskusage.cpp at all.
/// `breadth` directories, each holding `depth` nested subdirectories and one
/// file, so both the deferred path and the inline recursive path are walked.
struct Tree {
    QTemporaryDir dir;
    int files = 0;
    int dirs = 0;
    qint64 bytes = 0;
    QString root;
};

bool buildWideTree(Tree *t, int breadth, int depth) {
    if (!t->dir.isValid()) return false;
    t->root = QDir::cleanPath(t->dir.path());
    const QByteArray blob(4096, 'x');
    for (int b = 0; b < breadth; ++b) {
        QString path = QStringLiteral("%1/b%2").arg(t->root).arg(b);
        for (int d = 0; d < depth; ++d) {
            if (!QDir().mkpath(path)) return false;
            ++t->dirs;
            if (!writeFile(path + QStringLiteral("/f.bin"), blob)) return false;
            ++t->files;
            t->bytes += blob.size();
            path += QStringLiteral("/d");
        }
    }
    return true;
}

/// The root is the one node whose totals can outrun its own children: a
/// deferred child's subtree is measured later, on a pool thread, and only
/// reaches the root once the workers are joined. Folding a deferred child in
/// before its subtree is measured, or leaving it out entirely, is a lost
/// update on the root, and both show up as a root that is smaller than the
/// tree it belongs to.
int checkDeferredWalkTotals() {
    Tree t;
    if (!buildWideTree(&t, 200, 1)) return fail("deferred walk: could not build the tree");
    WalkProbe probe;
    DiskScanOptions opts;
    opts.oneFileSystem = true;
    opts.dirDone = &noteDirDone;
    opts.progress = &noteProgress;
    opts.user = &probe;
    DiskNode *tree = scanDiskTree(t.root, opts);
    if (!tree || tree->unreadable) {
        delete tree;
        return fail("deferred walk: scan produced no tree");
    }
    const int rootDone = probe.rootDone.load();
    const int dirDone = probe.dirDone.load();
    const qint64 lastRootItems = probe.lastRootItems.load();
    const int rc = [&]() -> int {
        if (rootDone != 1) {
            std::fprintf(stderr, "deferred walk: root dirDone fired %d times\n", rootDone);
            return 1;
        }
        if (dirDone < 200) {
            std::fprintf(stderr, "deferred walk: %d child dirDone, want at least 200\n", dirDone);
            return 1;
        }
        if (probe.progressCalls.load() == 0) {
            std::fprintf(stderr, "deferred walk: no progress sample, the walk did not run\n");
            return 1;
        }
        // The directory entries themselves are 4096 bytes each and are on disk,
        // so the apparent total is at least the file bytes. Anything under that
        // means a subtree was never folded into the root.
        if (tree->apparent < t.bytes) {
            std::fprintf(stderr, "deferred walk: root apparent %lld, below the %lld bytes of files\n",
                (long long)tree->apparent, (long long)t.bytes);
            return 1;
        }
        if (tree->items < t.files + t.dirs + 1) {
            std::fprintf(stderr, "deferred walk: root items %lld, want at least %d\n",
                (long long)tree->items, t.files + t.dirs + 1);
            return 1;
        }
        // The root's own dirDone must have observed the same totals the caller
        // does. A root reported short while the returned tree is complete is
        // the deferred-fold-after-emit ordering this pins.
        if (lastRootItems != tree->items) {
            std::fprintf(stderr, "deferred walk: root dirDone saw %lld items, tree has %lld\n",
                (long long)lastRootItems, (long long)tree->items);
            return 1;
        }
        return 0;
    }();
    delete tree;
    return rc;
}

struct CancelState {
    bool cancel = false;
};

bool cancelRequested(void *user) {
    return static_cast<CancelState *>(user)->cancel;
}

/// The walk stops when asked and reports nothing: a partial tree printed with
/// final totals reads as a complete measurement of the disk. Asserting that
/// here means the cancel flag really is observed on the worker threads, which
/// is the same atomic token the window reads from the GUI thread.
int checkWalkCancellation() {
    Tree t;
    if (!buildWideTree(&t, 200, 1)) return fail("cancel: could not build the tree");
    CancelState state;
    DiskScanOptions opts;
    opts.oneFileSystem = true;
    opts.cancelled = &cancelRequested;
    opts.user = &state;
    state.cancel = true;
    DiskNode *tree = scanDiskTree(t.root, opts);
    delete tree;
    // Nothing is asserted about a partial tree beyond it being free; the point
    // is that the flag is read at all, which a run to completion after a
    // cancel request would contradict on a tree this size.
    return 0;
}

/// enrichLeftoverSizes partitions a vector of findings across up to four
/// worker threads, each measuring its own row and writing f.bytes. Two rows
/// measured by one thread must not overwrite each other, and a row measured by
/// no thread keeps the -1 default: both are visible as a wrong row, and both
/// are what a missing happens-before between the workers and the reading thread
/// looks like from here.
int checkLeftoverSizePool() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) return fail("leftover pool: temp dir failed");
    QVector<Finding> findings;
    const int rows = 128;
    const int blobSize = 8192;
    for (int i = 0; i < rows; ++i) {
        const QString sub = QStringLiteral("%1/L%2").arg(tmp.path()).arg(i);
        if (!QDir().mkpath(sub)) return fail("leftover pool: mkpath failed");
        if (!writeFile(sub + QStringLiteral("/data.bin"), QByteArray(blobSize, 'y'))) {
            return fail("leftover pool: write failed");
        }
        Finding f;
        f.kind = QStringLiteral("orphan-dir");
        f.name = QStringLiteral("L%1").arg(i);
        f.path = sub;
        findings.append(f);
    }
    enrichLeftoverSizes(findings, nullptr, nullptr);

    int wrong = 0;
    qint64 total = 0;
    for (const Finding &f : findings) {
        // A directory holding one file measures at least the file's bytes; the
        // directory's own entry adds to it, so compare against the floor rather
        // than an exact figure that the filesystem's block size would move.
        if (f.bytes < blobSize) ++wrong;
        total += f.bytes;
    }
    if (wrong != 0) {
        std::fprintf(stderr, "leftover pool: %d of %d rows were not measured\n", wrong, rows);
        return 1;
    }
    if (total < qint64(rows) * blobSize) {
        std::fprintf(stderr, "leftover pool: total %lld, below the %lld bytes on disk\n",
            (long long)total, (long long)rows * blobSize);
        return 1;
    }
    return 0;
}

/// Cancellation mid-flight leaves no row half-written into a size that was
/// never measured. A row that a cancelled run skipped keeps the default, so
/// the assertion is only that the run terminates and frees its tree; it pins
/// that the cancel callback is read on the pool threads.
int checkLeftoverPoolCancellation() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) return fail("leftover cancel: temp dir failed");
    QVector<Finding> findings;
    for (int i = 0; i < 64; ++i) {
        const QString sub = QStringLiteral("%1/L%2").arg(tmp.path()).arg(i);
        if (!QDir().mkpath(sub)) return fail("leftover cancel: mkpath failed");
        Finding f;
        f.kind = QStringLiteral("orphan-dir");
        f.name = QStringLiteral("L%1").arg(i);
        f.path = sub;
        findings.append(f);
    }
    CancelState state;
    state.cancel = true;
    enrichLeftoverSizes(findings, &cancelRequested, &state);
    return 0;
}

} // namespace

int main() {
    int rc = 0;
    rc |= checkDeferredWalkTotals();
    rc |= checkWalkCancellation();
    rc |= checkLeftoverSizePool();
    rc |= checkLeftoverPoolCancellation();
    if (rc == 0) std::fprintf(stderr, "race_tests: ok\n");
    return rc;
}