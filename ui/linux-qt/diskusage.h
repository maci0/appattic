#ifndef APPATTIC_DISKUSAGE_H
#define APPATTIC_DISKUSAGE_H

#include <QString>
#include <QVector>
#include <cstdint>

struct DiskNode {
    QString name;
    QString path;
    qint64 apparent = 0;
    qint64 allocated = 0;
    qint64 items = 0;
    qint64 mtime = 0;
    quint64 device = 0;
    bool isDir = false;
    bool unreadable = false;
    bool mountPoint = false;
    DiskNode *parent = nullptr;
    QVector<DiskNode *> children;

    ~DiskNode();
    DiskNode() = default;
    DiskNode(const DiskNode &) = delete;
    DiskNode &operator=(const DiskNode &) = delete;

    qint64 metric(bool allocatedSize) const { return allocatedSize ? allocated : apparent; }
    void sortChildren(bool allocatedSize);
};

struct DiskVolume {
    QString name;
    QString rootPath;
    QString device;
    QString fileSystem;
    qint64 bytesTotal = 0;
    qint64 bytesAvailable = 0;
    bool isRoot = false;
    bool isHome = false;
    bool readOnly = false;
};

struct DiskScanOptions {
    bool oneFileSystem = true;
    bool (*cancelled)(void *user) = nullptr;
    void (*progress)(qint64 dirs, const QString &path, void *user) = nullptr;
    /// Called when a directory's walk ends, so its subtree is complete. The
    /// walk is threaded, so this runs on any of the scan pool's threads, and
    /// up to eight at once: take a copy and post it, do not touch shared state
    /// without a lock. The reference only lives for the call. Deferred
    /// hard-link totals can still be added to it.
    void (*dirDone)(const DiskNode &node, void *user) = nullptr;
    void *user = nullptr;
};

DiskNode *scanDiskTree(const QString &root, const DiskScanOptions &opts);
/// Allocated bytes for a file or directory tree. -1 if the path cannot be read.
qint64 measurePathBytes(const QString &path, const DiskScanOptions &opts = DiskScanOptions());
QVector<DiskVolume> listDiskVolumes();
/// Bytes a volume row reports as used, so the row reconciles:
/// `used + available == total`.
///
/// The two free counts a volume reports are not the same number.
/// `QStorageInfo::bytesFree` is every free block (`f_bfree`) and counts the
/// pool ext4 reserves for root, which an unprivileged process cannot write;
/// `bytesAvailable` is what one can use (`f_bavail`). Subtracting the larger
/// from the total makes the reserved blocks read as used, so on a 100 GB
/// volume with 5 GB reserved the row shows 51 GB used next to 44 GB
/// available, and the columns sum past the size. Total minus available is
/// the pair that adds up, and it is what the Swift volume list carries.
qint64 volumeUsedBytes(qint64 total, qint64 available);
QString diskContentsLabel(qint64 items, bool isDir);
QString diskModifiedLabel(qint64 mtime);

#endif
