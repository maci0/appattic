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
    qint64 bytesFree = 0;
    qint64 bytesAvailable = 0;
    bool isRoot = false;
    bool isHome = false;
    bool readOnly = false;
};

struct DiskScanOptions {
    bool oneFileSystem = true;
    bool (*cancelled)(void *user) = nullptr;
    void (*progress)(qint64 dirs, const QString &path, void *user) = nullptr;
    void *user = nullptr;
};

DiskNode *scanDiskTree(const QString &root, const DiskScanOptions &opts);
/// Allocated bytes for a file or directory tree. -1 if the path cannot be read.
qint64 measurePathBytes(const QString &path, const DiskScanOptions &opts = DiskScanOptions());
QVector<DiskVolume> listDiskVolumes();
QString diskContentsLabel(qint64 items, bool isDir);
QString diskModifiedLabel(qint64 mtime);
int smokeDiskUsage();

#endif
