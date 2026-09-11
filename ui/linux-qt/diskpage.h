#ifndef APPATTIC_DISKPAGE_H
#define APPATTIC_DISKPAGE_H

#include <QWidget>

class DiskNode;
class QLineEdit;

class DiskPage : public QWidget {
    Q_OBJECT
public:
    explicit DiskPage(QWidget *parent = nullptr);
    ~DiskPage() override;

    void setSearch(const QString &text);
    void scanHome();
    void scanFolder();
    void scanFilesystem();
    void scanRemote();
    bool isScanning() const { return m_scanning; }

signals:
    void statusMessage(const QString &text);

private:
    void refreshVolumes();
    void startScan(const QString &path);
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
