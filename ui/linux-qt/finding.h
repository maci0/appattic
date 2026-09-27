#ifndef APPATTIC_FINDING_H
#define APPATTIC_FINDING_H

#include <QByteArray>
#include <QDateTime>
#include <QJsonObject>
#include <QMetaType>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVector>
#include <optional>

enum class Page : int {
    Overview = 0,
    Leftovers,
    Stale,
    Outdated,
    Packages,
    DiskUsage,
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

    // U+001E, not '\n': every field here is filesystem text, and a newline is
    // a legal byte in a Linux filename, so a '\n'-joined key can be produced by
    // two different findings. The sibling key for the same job already uses
    // U+001E (see packageChildMarkKey), a byte a POSIX filename cannot contain.
    QString uid() const {
        static const QChar sep(0x1e);
        return plugin + sep + id + sep + path + sep + kind + sep + name;
    }
};

Q_DECLARE_METATYPE(Finding)

QString jsonStr(const QJsonObject &o, const char *key);
QString pathIdentityKey(const QString &path);
QDateTime parseIsoInstant(const QString &value);
QString redactHomePaths(const QString &text, const QString &home = QString());
/// WASM path plugins list `/home/user/...`. host.exec rewrites that argv to the
/// configured XDG root, or to $HOME when the variable is unset; findings JSON
/// still uses the placeholder until ingest.
QString expandHomeUserPlaceholder(const QString &text, const QString &home = QString());
bool restrictOwnerOnlyFile(const QString &path);
bool restrictOwnerOnlyDir(const QString &path);
void restrictPrivateDataFile(const QString &path);
QString shellQuote(const QString &s);
bool scriptHasCommands(const QString &script);
QString humanSize(qint64 bytes);
QString localeCount(qlonglong n);
QString localeDateLabel(const QDate &date);
QString localeDateTimeLabel(const QDateTime &dt);
QString humanKind(const QString &kind);
QString pluginScanLabel(const QString &pluginId);
QString managerLabel(const Finding &f);
QString locationLabel(const Finding &f);
QString modifiedLabel(const Finding &f, const QDateTime &now = QDateTime::currentDateTime());
QString displayName(const Finding &f);
QString statusLabel(const Finding &f);
bool isProtectedPackagedPath(const QString &path);
bool isShadowFinding(const Finding &f);
QString leftoverCleanupCommand(const Finding &f);
QString packageChildCommand(const Finding &f, const QString &child);
/// The two halves of a guarded removal, `if <present>; then <action>; fi`, so
/// the root wrapper and the privilege check read one shape. Mirrors Swift
/// `GuardedRemove` in `Sources/AppAtticScan/ShellScript.swift`.
struct GuardedRemove {
    QString present;
    QString action;
};

/// Split a single-line guarded removal. Null for anything else.
std::optional<GuardedRemove> parseGuardedRemove(const QString &cmd);
bool commandNeedsRoot(const QString &cmd);
/// A plugin command may only reach a script when every byte is inert to
/// `/bin/sh`. Anything else is an unquoted name or path.
bool commandIsShellSafe(const QString &cmd);
QString withRootCmd(const QString &cmd);
QString scriptRootHelper();
void groupLinuxLeftovers(QVector<Finding> &findings);
bool isLeftover(const Finding &f);
bool isOutdated(const Finding &f);
/// Same manager list as Swift `outdatedIsUpdatable`, plus a kind gate: only a
/// kind naming an outdated or upgrade row (or no kind at all) can be upgraded.
/// Homebrew, Flatpak, and named distro upgrades stay updatable after confirm.
/// App Store, Snap, language globals, and untrusted casks stay report-only.
bool outdatedIsUpdatable(const QString &manager, const QString &kind);
bool hasUsageTiming(const Finding &f);
bool isStaleTierStatus(const QString &status);
bool isStale(const Finding &f);
void enrichLeftoverUsageTiming(Finding &f, const QDateTime &now = QDateTime::currentDateTime());
void enrichFindingsUsageTiming(QVector<Finding> &findings, const QDateTime &now = QDateTime::currentDateTime());
void enrichLeftoverSizes(
    QVector<Finding> &findings,
    bool (*cancelled)(void *user) = nullptr,
    void *user = nullptr
);
bool leftoverNameMatchesDesktop(const QString &name, const QSet<QString> &stems);
void markOwnedPathLeftovers(QVector<Finding> &findings);
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
/// Lowercased, NFC search haystack (name, path, kind, manager, status, packaged
/// path, summary, reason, extra paths). Built on demand by the UI filter.
/// Compare it against `searchFold(query)`, not a bare `toLower()`.
QString searchHaystack(const Finding &f);
/// Case form both sides of a search use: POSIX-independent lowercase in NFC,
/// so a decomposed filename from the disk matches a precomposed query.
QString searchFold(const QString &s);

#endif
