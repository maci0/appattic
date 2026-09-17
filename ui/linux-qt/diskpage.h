#ifndef APPATTIC_DISKPAGE_H
#define APPATTIC_DISKPAGE_H

#include <QWidget>

struct DiskNode;
class QLineEdit;

class DiskPage : public QWidget {
    Q_OBJECT
public:
    explicit DiskPage(QWidget *parent = nullptr);
    ~DiskPage() override;

    void scanHome();
    void scanFolder();
    void scanFilesystem();
    void scanRemote();
    /// Scan one path. Called by the buttons above and by the smoke checks.
    void startScan(const QString &path);

    /// Rows the running scan drew before it finished, and whether any of them
    /// arrived before the final fill. The gate in main.cpp checks both.
    int streamedRows() const;
    /// Ring segments the running scan drew: one per finished folder.
    int streamedSegments() const;
    bool streamedBeforeFinish() const;
    bool isScanning() const { return m_scanning; }

signals:
    void statusMessage(const QString &text);

private:
    void refreshVolumes();
    void stopScan();
    void rescan();
    void fillTree();
    void fillTreeFiltered();
    void selectNode(DiskNode *node);
    void openSelected();
    void trashSelected();
    void copyPath();
    void goUp();
    void updateChrome();
    void showLocations();
    void showScan();

    class Impl;
    Impl *d;
    bool m_scanning = false;
};

#endif
