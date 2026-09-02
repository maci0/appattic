#ifndef APPATTIC_FINDING_H
#define APPATTIC_FINDING_H

#include <QByteArray>
#include <QDateTime>
#include <QJsonObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVector>

enum class Page : int {
    Overview = 0,
    Leftovers,
    Stale,
    Outdated,
    Packages,
    Settings,
};

struct Finding {
    QString plugin;
    QString engine;
    QString kind;
    QString id;
    QString name;
    QString path;
    QString status;
    QString command;
    QString reason;
    QString summary;
    QString rootLabel;
    QString manager;
    QString revision;
    QString currentVersion;
    QString latestVersion;
    QString lastUsed;
    QString mtime;
    QString version;
    QString dialogBody;
    QString updateCommand;
    QString packagedPath;
    qint64 bytes = -1;
    qint64 idleDays = -1;
    bool updatable = false;
    QStringList children;
    QStringList extraPaths;

    QString uid() const {
        return plugin + QLatin1Char('\n') + id + QLatin1Char('\n') + path + QLatin1Char('\n')
            + kind + QLatin1Char('\n') + name;
    }
};

QString jsonStr(const QJsonObject &o, const char *key);
QString pathIdentityKey(const QString &path);
QDateTime parseIsoInstant(const QString &value);
QString redactHomePaths(const QString &text, const QString &home = QString());
bool restrictOwnerOnlyFile(const QString &path);
bool restrictOwnerOnlyDir(const QString &path);
void restrictPrivateDataFile(const QString &path);
QString shellQuote(const QString &s);
bool scriptHasCommands(const QString &script);
QString humanSize(qint64 bytes);
QString humanKind(const QString &kind);
QString managerLabel(const Finding &f);
QString locationLabel(const Finding &f);
QString modifiedLabel(const Finding &f, const QDateTime &now = QDateTime::currentDateTime());
QString displayName(const Finding &f);
QString statusLabel(const Finding &f);
bool isProtectedPackagedPath(const QString &path);
bool isShadowFinding(const Finding &f);
QString leftoverCleanupCommand(const Finding &f);
bool isLeftover(const Finding &f);
bool isOutdated(const Finding &f);
/// Same rule as Swift `outdatedIsUpdatable`: Homebrew formulae/casks and Flatpak
/// can be updated after confirm. Distro, language, and untrusted casks stay report-only.
bool outdatedIsUpdatable(const QString &manager, const QString &kind);
bool hasUsageTiming(const Finding &f);
bool isStaleTierStatus(const QString &status);
bool isStaleFromLeftoverUsage(const Finding &f);
bool isStale(const Finding &f);
void enrichLeftoverUsageTiming(Finding &f);
void enrichFindingsUsageTiming(QVector<Finding> &findings);
bool isPackage(const Finding &f);
bool matchPage(const Finding &f, Page page);
int countPageRows(const QVector<Finding> &findings, Page page);
void appendFindingsFromBlob(QVector<Finding> &out, const QByteArray &line);
bool isGlobalKind(const Finding &f);
QString distroManager(const Finding &f);
bool canMarkManual(const Finding &f);
QString markManualCommand(const Finding &f);
bool canMarkCleanup(const Finding &f, Page page);
QStringList leftoverIgnoreKeys(const Finding &f);
bool leftoverIsIgnored(const Finding &f, const QSet<QString> &ignored);

#endif
