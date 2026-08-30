#include "embed.h"

#include <QAbstractItemView>
#include <QApplication>
#include <QByteArray>
#include <QCheckBox>
#include <QClipboard>
#include <QColor>
#include <QComboBox>
#include <QDateTime>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QFontMetrics>
#include <QFrame>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QKeySequence>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QListWidgetItem>
#include <QMainWindow>
#include <QMenu>
#include <QMenuBar>
#include <QAction>
#include <QMessageBox>
#include <QModelIndex>
#include <QObject>
#include <QPainter>
#include <QPalette>
#include <QPlainTextEdit>
#include <QProcess>
#include <QPushButton>
#include <QRect>
#include <QScrollArea>
#include <QSet>
#include <QSettings>
#include <QSignalBlocker>
#include <QSize>
#include <QSplitter>
#include <QStackedWidget>
#include <QStandardPaths>
#include <QStatusBar>
#include <QStyle>
#include <QStyleHints>
#include <QStyleOptionViewItem>
#include <QStyledItemDelegate>
#include <QTemporaryFile>
#include <QThread>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QUrl>
#include <QVBoxLayout>
#include <QVector>
#include <QWidget>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <utility>
#include <vector>

static void resetWidgetPalette(QWidget *w) {
    if (!w) return;
    w->setAttribute(Qt::WA_SetPalette, false);
    w->setPalette(QApplication::palette());
}

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

static int homePathTag(const char *xdgEnv, const QString &rel);
static QStringList pluginWasmFiles(const QString &out);

static void on_json(const char *json, size_t len, void *user) {
    auto *out = static_cast<QByteArray *>(user);
    out->append(json, int(len));
    out->append('\n');
}

static QString coreOutDir() {
    const QByteArray env = qgetenv("APPATTIC_CORE_OUT");
    if (!env.isEmpty()) return QString::fromUtf8(env);
    return QString::fromUtf8(APPATTIC_CORE_OUT);
}

static int pluginTag(const QString &wasmPath) {
    const QFileInfo fi(wasmPath);
    const QString stem = fi.completeBaseName();
    if (stem.contains(QLatin1String("container_runtime"))) {
        if (!QStandardPaths::findExecutable(QStringLiteral("podman")).isEmpty()) return 2;
        if (!QStandardPaths::findExecutable(QStringLiteral("docker")).isEmpty()) return 1;
        return 0;
    }
    if (stem.contains(QLatin1String("snapd"))) {
        return QStandardPaths::findExecutable(QStringLiteral("snap")).isEmpty() ? 0 : 1;
    }
    if (stem.contains(QLatin1String("path_xdg_config"))) {
        return homePathTag("XDG_CONFIG_HOME", QStringLiteral(".config"));
    }
    if (stem.contains(QLatin1String("path_xdg_data"))) {
        return homePathTag("XDG_DATA_HOME", QStringLiteral(".local/share"));
    }
    if (stem.contains(QLatin1String("path_xdg_cache"))) {
        return homePathTag("XDG_CACHE_HOME", QStringLiteral(".cache"));
    }
    if (stem.contains(QLatin1String("path_xdg_state"))) {
        return homePathTag("XDG_STATE_HOME", QStringLiteral(".local/state"));
    }
    if (stem.contains(QLatin1String("path_xdg_lib"))) {
        return QDir::home().exists(QStringLiteral(".local/lib")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_var_app"))) {
        return QDir::home().exists(QStringLiteral(".var/app")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_shadow"))) {
        const QDir home = QDir::home();
        if (home.exists(QStringLiteral(".local/bin"))) return 1;
        if (home.exists(QStringLiteral("bin"))) return 1;
        if (home.exists(QStringLiteral(".cargo/bin"))) return 1;
        if (home.exists(QStringLiteral(".local/share/applications"))) return 1;
        return 0;
    }
    if (stem.contains(QLatin1String("path_user_bin"))) {
        if (QDir::home().exists(QStringLiteral(".local/bin"))) return 1;
        if (QDir::home().exists(QStringLiteral("bin"))) return 1;
        return 0;
    }
    if (stem.contains(QLatin1String("path_home_dot"))) {
        return QDir::home().exists() ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_application_support"))) {
        return QDir::home().exists(QStringLiteral("Library/Application Support")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_caches"))) {
        return QDir::home().exists(QStringLiteral("Library/Caches")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_preferences"))) {
        return QDir::home().exists(QStringLiteral("Library/Preferences")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_saved_state"))) {
        return QDir::home().exists(QStringLiteral("Library/Saved Application State")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_containers")) &&
        !stem.contains(QLatin1String("path_group_containers"))) {
        return QDir::home().exists(QStringLiteral("Library/Containers")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_group_containers"))) {
        return QDir::home().exists(QStringLiteral("Library/Group Containers")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_logs"))) {
        return QDir::home().exists(QStringLiteral("Library/Logs")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_webkit"))) {
        return QDir::home().exists(QStringLiteral("Library/WebKit")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_httpstorages"))) {
        return QDir::home().exists(QStringLiteral("Library/HTTPStorages")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("path_launchagents"))) {
        return QDir::home().exists(QStringLiteral("Library/LaunchAgents")) ? 1 : 0;
    }
    if (stem.contains(QLatin1String("pacman"))) {
        return QStandardPaths::findExecutable(QStringLiteral("pacman")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("apt")) {
        if (!QStandardPaths::findExecutable(QStringLiteral("apt-get")).isEmpty()) return 1;
        if (!QStandardPaths::findExecutable(QStringLiteral("apt")).isEmpty()) return 1;
        return 0;
    }
    if (stem == QLatin1String("dnf")) {
        if (!QStandardPaths::findExecutable(QStringLiteral("dnf5")).isEmpty()) return 1;
        if (!QStandardPaths::findExecutable(QStringLiteral("dnf")).isEmpty()) return 1;
        if (!QStandardPaths::findExecutable(QStringLiteral("yum")).isEmpty()) return 1;
        return 0;
    }
    if (stem == QLatin1String("zypper")) {
        return QStandardPaths::findExecutable(QStringLiteral("zypper")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("flatpak")) {
        return QStandardPaths::findExecutable(QStringLiteral("flatpak")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("npm")) {
        return QStandardPaths::findExecutable(QStringLiteral("npm")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("pnpm")) {
        return QStandardPaths::findExecutable(QStringLiteral("pnpm")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("bun")) {
        return QStandardPaths::findExecutable(QStringLiteral("bun")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("pipx")) {
        return QStandardPaths::findExecutable(QStringLiteral("pipx")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("pip")) {
        if (!QStandardPaths::findExecutable(QStringLiteral("pip")).isEmpty()) return 1;
        if (!QStandardPaths::findExecutable(QStringLiteral("pip3")).isEmpty()) return 1;
        return 0;
    }
    if (stem == QLatin1String("uv")) {
        return QStandardPaths::findExecutable(QStringLiteral("uv")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("brew")) {
        return QStandardPaths::findExecutable(QStringLiteral("brew")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("gem")) {
        return QStandardPaths::findExecutable(QStringLiteral("gem")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("composer")) {
        return QStandardPaths::findExecutable(QStringLiteral("composer")).isEmpty() ? 0 : 1;
    }
    return 1;
}

static qint64 jsonInt(const QJsonObject &o, const char *key) {
    const QJsonValue v = o.value(QLatin1String(key));
    if (v.isDouble()) return qint64(v.toDouble());
    if (v.isString()) return v.toString().toLongLong();
    return -1;
}

static QString jsonStr(const QJsonObject &o, const char *key) {
    const QJsonValue v = o.value(QLatin1String(key));
    if (v.isString()) return v.toString();
    if (v.isDouble()) return QString::number(v.toDouble(), 'f', 0);
    return {};
}

static QString jsonStrAny(const QJsonObject &o, std::initializer_list<const char *> keys) {
    for (const char *key : keys) {
        const QString s = jsonStr(o, key);
        if (!s.isEmpty()) return s;
    }
    return {};
}

static qint64 jsonIntAny(const QJsonObject &o, std::initializer_list<const char *> keys) {
    for (const char *key : keys) {
        const qint64 n = jsonInt(o, key);
        if (n >= 0) return n;
    }
    return -1;
}

static bool jsonBool(const QJsonObject &o, const char *key) {
    const QJsonValue v = o.value(QLatin1String(key));
    if (v.isBool()) return v.toBool();
    if (v.isDouble()) return v.toDouble() != 0;
    if (v.isString()) {
        const QString s = v.toString().toLower();
        return s == QLatin1String("true") || s == QLatin1String("1") || s == QLatin1String("yes");
    }
    return false;
}

static QString shellQuote(const QString &s) {
    QString q = s;
    q.replace(QLatin1Char('\''), QStringLiteral("'\\''"));
    return QLatin1Char('\'') + q + QLatin1Char('\'');
}

static bool scriptHasCommands(const QString &script) {
    const QStringList lines = script.split(QLatin1Char('\n'));
    for (const QString &raw : lines) {
        const QString t = raw.trimmed();
        if (t.isEmpty() || t.startsWith(QLatin1Char('#'))) continue;
        if (t == QLatin1String("#!/bin/sh") || t.startsWith(QLatin1String("set "))) continue;
        return true;
    }
    return false;
}

static bool isDarkPalette(const QPalette &p) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    const Qt::ColorScheme scheme = QGuiApplication::styleHints()->colorScheme();
    if (scheme == Qt::ColorScheme::Dark) return true;
    if (scheme == Qt::ColorScheme::Light) return false;
#endif
    return p.color(QPalette::Window).lightness() < 128;
}

static QFont bodyFont() {
    return QApplication::font();
}

static QFont smallFont() {
    QFont f = QApplication::font();
    const int ps = f.pointSize();
    if (ps > 0) f.setPointSize(qMax(9, ps - 2));
    else if (f.pixelSize() > 0) f.setPixelSize(qMax(11, f.pixelSize() - 2));
    return f;
}

static int rowPx() {
    return QFontMetrics(bodyFont()).height() + 6;
}

static int homePathTag(const char *xdgEnv, const QString &rel) {
    const QByteArray env = qgetenv(xdgEnv);
    if (!env.isEmpty()) return QDir(QString::fromUtf8(env)).exists() ? 1 : 0;
    return QDir::home().exists(rel) ? 1 : 0;
}

static QStringList pluginWasmFiles(const QString &out) {
    const QStringList names = {
        QStringLiteral("/container_runtime.wasm"),
        QStringLiteral("/snapd.wasm"),
        QStringLiteral("/path_xdg_config.wasm"),
        QStringLiteral("/path_xdg_data.wasm"),
        QStringLiteral("/path_xdg_cache.wasm"),
        QStringLiteral("/path_xdg_state.wasm"),
        QStringLiteral("/path_xdg_lib.wasm"),
        QStringLiteral("/path_var_app.wasm"),
        QStringLiteral("/path_shadow.wasm"),
        QStringLiteral("/path_user_bin.wasm"),
        QStringLiteral("/path_home_dot.wasm"),
        QStringLiteral("/path_application_support.wasm"),
        QStringLiteral("/path_caches.wasm"),
        QStringLiteral("/path_preferences.wasm"),
        QStringLiteral("/path_saved_state.wasm"),
        QStringLiteral("/path_containers.wasm"),
        QStringLiteral("/path_group_containers.wasm"),
        QStringLiteral("/path_logs.wasm"),
        QStringLiteral("/path_webkit.wasm"),
        QStringLiteral("/path_httpstorages.wasm"),
        QStringLiteral("/path_launchagents.wasm"),
        QStringLiteral("/pacman.wasm"),
        QStringLiteral("/apt.wasm"),
        QStringLiteral("/dnf.wasm"),
        QStringLiteral("/zypper.wasm"),
        QStringLiteral("/flatpak.wasm"),
        QStringLiteral("/npm.wasm"),
        QStringLiteral("/pnpm.wasm"),
        QStringLiteral("/bun.wasm"),
        QStringLiteral("/pipx.wasm"),
        QStringLiteral("/uv.wasm"),
        QStringLiteral("/brew.wasm"),
        QStringLiteral("/gem.wasm"),
        QStringLiteral("/composer.wasm"),
        QStringLiteral("/pip.wasm"),
    };
    QStringList paths;
    paths.reserve(names.size());
    for (const QString &n : names) paths << (out + n);
    return paths;
}

static QString humanSize(qint64 bytes) {
    if (bytes < 0) return QStringLiteral("unknown");
    double n = double(bytes);
    static const char *units[] = {"B", "KB", "MB", "GB", "TB"};
    for (const char *unit : units) {
        if (qAbs(n) < 1024.0) {
            if (unit[0] == 'B' && unit[1] == '\0') return QString::number(int(n)) + QStringLiteral(" B");
            return QString::number(n, 'f', 1) + QLatin1Char(' ') + QLatin1String(unit);
        }
        n /= 1024.0;
    }
    return QString::number(n, 'f', 1) + QStringLiteral(" PB");
}

static QString humanKind(const QString &kind) {
    if (kind == QLatin1String("global")) return QStringLiteral("Global");
    if (kind == QLatin1String("orphan") || kind.contains(QLatin1String("orphan"))) {
        return QStringLiteral("Orphan");
    }
    QString s = kind;
    s.replace(QLatin1Char('-'), QLatin1Char(' '));
    if (!s.isEmpty()) s[0] = s[0].toUpper();
    return s.isEmpty() ? QStringLiteral("-") : s;
}

static QString managerLabel(const Finding &f) {
    QString m = f.manager;
    if (m.isEmpty()) m = f.engine;
    if (m.isEmpty()) m = f.plugin;
    m.replace(QLatin1Char('-'), QLatin1Char(' '));
    return m;
}

static QString locationLabel(const Finding &f) {
    if (!f.rootLabel.isEmpty()) return f.rootLabel;
    if (f.path.isEmpty()) return QStringLiteral("-");
    const QFileInfo fi(f.path);
    const QString parent = fi.dir().dirName();
    return parent.isEmpty() ? f.path : parent;
}

static QString modifiedLabel(const Finding &f) {
    if (f.idleDays >= 0) {
        if (f.idleDays < 1) return QStringLiteral("Today");
        if (f.idleDays == 1) return QStringLiteral("Yesterday");
        return QString::number(f.idleDays) + QStringLiteral(" days ago");
    }
    if (!f.mtime.isEmpty()) return f.mtime.left(10);
    if (!f.lastUsed.isEmpty()) return f.lastUsed.left(10);
    return QStringLiteral("-");
}

static QString displayName(const Finding &f) {
    if (!f.name.isEmpty()) return f.name;
    if (!f.id.isEmpty()) return f.id;
    if (!f.path.isEmpty()) return QFileInfo(f.path).fileName();
    return QStringLiteral("-");
}

static QString statusLabel(const Finding &f) {
    if (f.status == QLatin1String("review")) return QStringLiteral("Review");
    if (f.status == QLatin1String("remove")) return QStringLiteral("Remove");
    if (f.status.isEmpty()) return QStringLiteral("-");
    QString s = f.status;
    s[0] = s[0].toUpper();
    return s;
}

static bool isProtectedPackagedPath(const QString &path) {
    if (path.isEmpty()) return false;
    return path.startsWith(QLatin1String("/usr/"))
        || path.startsWith(QLatin1String("/bin/"))
        || path.startsWith(QLatin1String("/sbin/"));
}

static bool isShadowFinding(const Finding &f) {
    return f.status == QLatin1String("shadow")
        || f.kind == QLatin1String("shadow")
        || !f.packagedPath.isEmpty();
}

static QString overlayRootLabel(const QString &path) {
    if (path.contains(QLatin1String("/.local/share/applications"))) {
        return QStringLiteral(".local/share/applications");
    }
    if (path.contains(QLatin1String("/.local/bin"))) return QStringLiteral(".local/bin");
    if (path.contains(QLatin1String("/.cargo/bin"))) return QStringLiteral(".cargo/bin");
    const QString homeBin = QDir::home().filePath(QStringLiteral("bin")) + QLatin1Char('/');
    if (path.startsWith(homeBin) || path == QDir::home().filePath(QStringLiteral("bin"))) {
        return QStringLiteral("bin");
    }
    return {};
}

static QString leftoverCleanupCommand(const Finding &f) {
    if (isShadowFinding(f)) {
        if (f.path.isEmpty()) return {};
        if (!f.packagedPath.isEmpty() && f.path == f.packagedPath) return {};
        if (isProtectedPackagedPath(f.path)) return {};
        return QStringLiteral("rm -f ") + shellQuote(f.path);
    }
    if (f.command.isEmpty()) return {};
    const QString cmd = f.command;
    if ((cmd.contains(QLatin1String("rm ")) || cmd.contains(QLatin1String("rm\t")))
        && (cmd.contains(QLatin1String(" /usr/"))
            || cmd.contains(QLatin1String(" '/usr/"))
            || cmd.contains(QLatin1String(" \"/usr/")))) {
        return {};
    }
    return cmd;
}

static bool isLeftover(const Finding &f) {
    if (f.plugin.startsWith(QLatin1String("path-"))) return true;
    if (f.kind.contains(QLatin1String("orphan-dir"))) return true;
    if (f.kind.contains(QLatin1String("orphan-user-data"))) return true;
    if (f.kind.contains(QLatin1String("overlay")) || isShadowFinding(f)) return true;
    return false;
}

static bool isOutdated(const Finding &f) {
    if (!f.currentVersion.isEmpty() || !f.latestVersion.isEmpty()) return true;
    if (f.kind.contains(QLatin1String("outdated")) || f.kind.contains(QLatin1String("upgrade"))) return true;
    if (f.status == QLatin1String("outdated") || f.updatable) return true;
    if (!f.updateCommand.isEmpty()) return true;
    return false;
}

static bool hasUsageTiming(const Finding &f) {
    return f.idleDays >= 0 || !f.mtime.isEmpty() || !f.lastUsed.isEmpty();
}

static bool isStaleTierStatus(const QString &status) {
    return status == QLatin1String("review") || status == QLatin1String("remove")
        || status == QLatin1String("stale");
}

/// Linux stand-in until a stale WASM plugin ships: path leftovers with idle/mtime
/// (Swift stale = installed apps with review/remove tier; same columns when JSON has timing).
static bool isStaleFromLeftoverUsage(const Finding &f) {
    return isLeftover(f) && !isShadowFinding(f) && hasUsageTiming(f);
}

static bool isStale(const Finding &f) {
    if (f.kind.contains(QLatin1String("stale")) || f.kind.contains(QLatin1String("unused-app"))
        || f.kind.contains(QLatin1String("stale-app"))) {
        return true;
    }
    if (f.plugin.contains(QLatin1String("stale"))) return true;
    if (f.status == QLatin1String("stale")) return true;
    if (isStaleTierStatus(f.status) && hasUsageTiming(f) && !isLeftover(f) && !isOutdated(f)) {
        return true;
    }
    return isStaleFromLeftoverUsage(f);
}

static void enrichLeftoverUsageTiming(Finding &f) {
    if (!isLeftover(f) || isShadowFinding(f) || hasUsageTiming(f) || f.path.isEmpty()) return;
    const QFileInfo fi(f.path);
    if (!fi.exists()) return;
    const QDateTime mt = fi.lastModified();
    if (!mt.isValid()) return;
    f.mtime = mt.toString(Qt::ISODate);
    const qint64 days = mt.daysTo(QDateTime::currentDateTime());
    f.idleDays = days < 0 ? 0 : days;
}

static void enrichFindingsUsageTiming(QVector<Finding> &findings) {
    for (Finding &f : findings) enrichLeftoverUsageTiming(f);
}

static bool isPackage(const Finding &f) {
    if (isLeftover(f) || isStale(f) || isOutdated(f)) return false;
    if (f.plugin == QLatin1String("container-runtime") || f.plugin == QLatin1String("snapd")
        || f.plugin == QLatin1String("flatpak")) {
        return true;
    }
    if (f.kind.contains(QLatin1String("image")) || f.kind.contains(QLatin1String("volume"))
        || f.kind.contains(QLatin1String("container")) || f.kind.contains(QLatin1String("revision"))
        || f.kind.contains(QLatin1String("compose")) || f.kind.contains(QLatin1String("pod"))
        || f.kind.contains(QLatin1String("cache"))) {
        return true;
    }
    if (f.kind == QLatin1String("global") || f.kind == QLatin1String("orphan")) return true;
    return false;
}

static bool matchPage(const Finding &f, Page page) {
    switch (page) {
    case Page::Overview:
        return true;
    case Page::Leftovers:
        return isLeftover(f);
    case Page::Stale:
        return isStale(f);
    case Page::Outdated:
        return isOutdated(f);
    case Page::Packages:
        return isPackage(f);
    case Page::Settings:
        return false;
    }
    return false;
}

static int countPageRows(const QVector<Finding> &findings, Page page) {
    int n = 0;
    for (const Finding &f : findings) {
        if (matchPage(f, page)) ++n;
    }
    return n;
}

static void appendFindingsFromBlob(QVector<Finding> &out, const QByteArray &line) {
    const QJsonDocument doc = QJsonDocument::fromJson(line);
    if (!doc.isObject()) return;
    const QJsonObject obj = doc.object();
    const QString plugin = obj.value(QStringLiteral("plugin")).toString();
    const QString engine = jsonStr(obj, "engine");
    QString dialogBody;
    const QJsonValue dialog = obj.value(QStringLiteral("dialog"));
    if (dialog.isObject()) {
        dialogBody = jsonStr(dialog.toObject(), "body");
    }
    const QString note = jsonStr(obj, "note");
    const QJsonArray findings = obj.value(QStringLiteral("findings")).toArray();
    for (const QJsonValue &v : findings) {
        const QJsonObject f = v.toObject();
        Finding row;
        row.plugin = plugin;
        row.engine = engine;
        row.kind = jsonStr(f, "kind");
        row.id = jsonStr(f, "id");
        row.name = jsonStr(f, "name");
        if (row.name.isEmpty()) row.name = row.id;
        row.path = jsonStr(f, "path");
        row.status = jsonStr(f, "status");
        row.command = jsonStrAny(f, {"command", "remove_command", "uninstall"});
        row.updateCommand = jsonStrAny(f, {"update_command", "upgrade_command", "upgrade"});
        row.reason = jsonStr(f, "reason");
        row.summary = jsonStr(f, "summary");
        row.rootLabel = jsonStrAny(f, {"rootLabel", "root_label", "root"});
        row.manager = jsonStrAny(f, {"manager", "package_manager"});
        row.revision = jsonStr(f, "revision");
        row.currentVersion = jsonStrAny(f, {"current_version", "currentVersion", "current"});
        row.latestVersion = jsonStrAny(f, {"latest_version", "latestVersion", "latest"});
        row.lastUsed = jsonStrAny(f, {"last_used", "lastUsed", "last-used"});
        row.mtime = jsonStrAny(f, {"mtime", "modified", "modified_at"});
        row.version = jsonStr(f, "version");
        row.packagedPath = jsonStrAny(f, {"packaged_path", "packagedPath", "shadows"});
        if (row.packagedPath.isEmpty()) {
            const QJsonValue sh = f.value(QStringLiteral("shadows"));
            if (sh.isArray()) {
                QStringList parts;
                for (const QJsonValue &p : sh.toArray()) {
                    if (p.isString() && !p.toString().isEmpty()) parts << p.toString();
                }
                row.packagedPath = parts.join(QLatin1Char('\n'));
            }
        }
        if (row.rootLabel.isEmpty() && isShadowFinding(row)) {
            row.rootLabel = overlayRootLabel(row.path);
        }
        row.dialogBody = row.reason.isEmpty() ? dialogBody : row.reason;
        if (row.dialogBody.isEmpty()) row.dialogBody = note;
        row.bytes = jsonIntAny(f, {"bytes", "size_bytes", "size"});
        row.idleDays = jsonIntAny(f, {"idleDays", "idle_days", "idle"});
        row.updatable = jsonBool(f, "updatable") || jsonBool(f, "update")
            || row.status == QLatin1String("outdated");
        if (row.updateCommand.isEmpty() && row.updatable) row.updateCommand = row.command;
        const QJsonValue kids = f.value(QStringLiteral("children"));
        if (kids.isArray()) {
            for (const QJsonValue &c : kids.toArray()) {
                if (c.isObject()) {
                    const QJsonObject co = c.toObject();
                    const QString n = jsonStrAny(co, {"name", "id"});
                    if (!n.isEmpty()) row.children << n;
                } else if (c.isString()) {
                    row.children << c.toString();
                }
            }
        }
        const char *extraKeys[] = {"extra_paths", "extraPaths"};
        for (const char *extraKey : extraKeys) {
            const QJsonValue extra = f.value(QLatin1String(extraKey));
            if (!extra.isArray()) continue;
            for (const QJsonValue &p : extra.toArray()) {
                if (p.isString() && !p.toString().isEmpty()) row.extraPaths << p.toString();
            }
        }
        row.extraPaths.removeDuplicates();
        out.push_back(row);
    }
}

static bool isGlobalKind(const Finding &f) {
    return f.kind.contains(QLatin1String("global"))
        || f.plugin == QLatin1String("npm") || f.plugin == QLatin1String("pnpm")
        || f.plugin == QLatin1String("bun") || f.plugin == QLatin1String("pipx")
        || f.plugin == QLatin1String("uv");
}

static QString distroManager(const Finding &f) {
    QString m = f.manager;
    if (m.isEmpty()) m = f.engine;
    if (m.isEmpty()) m = f.plugin;
    return m.toLower();
}

static bool canMarkManual(const Finding &f) {
    if (isGlobalKind(f)) return false;
    if (f.kind != QLatin1String("orphan") && !f.kind.contains(QLatin1String("orphan"))) return false;
    const QString m = distroManager(f);
    return m == QLatin1String("apt") || m == QLatin1String("pacman")
        || m == QLatin1String("dnf") || m == QLatin1String("zypper");
}

static QString markManualCommand(const Finding &f) {
    if (!canMarkManual(f)) return {};
    const QString q = shellQuote(displayName(f));
    const QString m = distroManager(f);
    if (m == QLatin1String("apt")) return QStringLiteral("apt-mark manual ") + q;
    if (m == QLatin1String("pacman")) return QStringLiteral("pacman -D --asexplicit ") + q;
    if (m == QLatin1String("dnf")) return QStringLiteral("dnf mark install ") + q;
    if (m == QLatin1String("zypper")) return QStringLiteral("zypper --non-interactive install ") + q;
    return {};
}

static bool canMarkCleanup(const Finding &f, Page page) {
    if (page == Page::Outdated) {
        return f.updatable || !f.updateCommand.isEmpty() || !f.latestVersion.isEmpty()
            || !f.command.isEmpty();
    }
    if (f.status == QLatin1String("keep")) return false;
    if (isLeftover(f)) return !leftoverCleanupCommand(f).isEmpty();
    return !f.command.isEmpty() || f.status == QLatin1String("orphaned")
        || f.status == QLatin1String("review") || isShadowFinding(f);
}

static QStringList leftoverIgnoreKeys(const Finding &f) {
    QStringList keys;
    if (!f.path.isEmpty()) keys << f.path;
    keys << f.extraPaths;
    if (keys.isEmpty()) keys << f.uid();
    keys.removeDuplicates();
    return keys;
}

static bool leftoverIsIgnored(const Finding &f, const QSet<QString> &ignored) {
    for (const QString &k : leftoverIgnoreKeys(f)) {
        if (ignored.contains(k)) return true;
    }
    return false;
}

struct Tone {
    QColor text;
    QColor dim;
    QColor red;
    QColor amber;
    QColor green;
};

static Tone toneFrom(const QPalette &p) {
    const bool dark = isDarkPalette(p);
    Tone t;
    t.text = p.color(QPalette::WindowText);
    t.dim = dark ? QColor(174, 174, 174) : QColor(82, 82, 82);
    t.red = dark ? QColor(255, 69, 58) : QColor(192, 28, 40);
    t.amber = dark ? QColor(255, 214, 10) : QColor(158, 102, 0);
    t.green = dark ? QColor(48, 209, 88) : QColor(36, 138, 61);
    return t;
}

static QColor statusColor(const Finding &f, const Tone &t, Page page) {
    if (page == Page::Packages) {
        return isGlobalKind(f) ? t.amber : t.red;
    }
    if (f.status == QLatin1String("orphaned") || f.status == QLatin1String("remove")) return t.red;
    if (f.status == QLatin1String("review") || f.status == QLatin1String("shadow")
        || f.status == QLatin1String("outdated")) {
        return t.amber;
    }
    if (f.status == QLatin1String("keep")) return t.green;
    return t.dim;
}

class ScanWorker : public QObject {
    Q_OBJECT
public slots:
    void run(const QString &core, const QStringList &pluginSpecs) {
        std::vector<QByteArray> specs;
        std::vector<char *> ptrs;
        specs.reserve(size_t(pluginSpecs.size()));
        ptrs.reserve(size_t(pluginSpecs.size()));
        for (const QString &p : pluginSpecs) specs.push_back(p.toUtf8());
        for (QByteArray &s : specs) ptrs.push_back(s.data());
        QByteArray blobs;
        char err[1024];
        err[0] = '\0';
        const QByteArray coreUtf8 = core.toUtf8();
        const int rc = appattic_wasm_run(
            coreUtf8.constData(),
            ptrs.empty() ? nullptr : ptrs.data(),
            int(ptrs.size()),
            on_json,
            &blobs,
            err,
            sizeof err
        );
        emit finished(blobs, QString::fromUtf8(err), rc);
    }
signals:
    void finished(const QByteArray &blobs, const QString &err, int rc);
};

class SidebarDelegate : public QStyledItemDelegate {
public:
    explicit SidebarDelegate(QObject *parent = nullptr) : QStyledItemDelegate(parent) {}

    void paint(QPainter *p, const QStyleOptionViewItem &opt, const QModelIndex &idx) const override {
        QStyleOptionViewItem o = opt;
        initStyleOption(&o, idx);
        const QWidget *w = o.widget;
        QStyle *style = w ? w->style() : QApplication::style();
        style->drawPrimitive(QStyle::PE_PanelItemViewItem, &o, p, w);

        const QString name = idx.data(Qt::DisplayRole).toString();
        const int count = idx.data(Qt::UserRole).toInt();
        QFont body = bodyFont();
        QFont small = smallFont();
        const QColor fg = o.palette.color(
            o.state & QStyle::State_Selected ? QPalette::HighlightedText : QPalette::Text
        );
        QColor dim = fg;
        if (!(o.state & QStyle::State_Selected)) {
            dim = toneFrom(o.palette).dim;
        } else {
            dim.setAlpha(230);
        }
        p->setPen(fg);
        p->setFont(body);
        QRect nameR = o.rect.adjusted(10, 0, -10, 0);
        QString countText;
        if (count > 0) {
            countText = QString::number(count);
            p->setFont(small);
            const int cw = p->fontMetrics().horizontalAdvance(countText) + 4;
            nameR.setRight(nameR.right() - cw);
            p->setPen(dim);
            p->drawText(
                QRect(nameR.right(), o.rect.top(), cw, o.rect.height()),
                Qt::AlignVCenter | Qt::AlignRight,
                countText
            );
            p->setPen(fg);
            p->setFont(body);
        }
        p->drawText(nameR, Qt::AlignVCenter | Qt::AlignLeft, name);
    }

    QSize sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &) const override {
        return QSize(opt.rect.width(), rowPx());
    }
};

class TableRowDelegate : public QStyledItemDelegate {
public:
    explicit TableRowDelegate(QObject *parent = nullptr) : QStyledItemDelegate(parent) {}

    void initStyleOption(QStyleOptionViewItem *option, const QModelIndex &index) const override {
        QStyledItemDelegate::initStyleOption(option, index);
        if (option->state & QStyle::State_Selected) {
            const QColor onAccent = option->palette.color(QPalette::HighlightedText);
            option->palette.setColor(QPalette::Text, onAccent);
            option->palette.setColor(QPalette::WindowText, onAccent);
            option->palette.setBrush(QPalette::Text, onAccent);
            option->palette.setBrush(QPalette::WindowText, onAccent);
        }
    }

    QSize sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &index) const override {
        QSize s = QStyledItemDelegate::sizeHint(opt, index);
        s.setHeight(rowPx());
        return s;
    }
};

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    explicit MainWindow() {
        setWindowTitle(QStringLiteral("AppAttic"));
        resize(1180, 720);
        QFont body = bodyFont();
        setFont(body);

        m_scanThread = new QThread(this);
        m_worker = new ScanWorker;
        m_worker->moveToThread(m_scanThread);
        m_scanThread->start();
        connect(this, &MainWindow::requestScan, m_worker, &ScanWorker::run);
        connect(m_worker, &ScanWorker::finished, this, &MainWindow::scanFinished);

        auto *outer = new QSplitter(Qt::Horizontal, this);
        outer->setChildrenCollapsible(false);

        m_sidebar = new QListWidget;
        m_sidebar->setFixedWidth(220);
        m_sidebar->setFrameShape(QFrame::NoFrame);
        m_sidebar->setContentsMargins(8, 8, 8, 8);
        m_sidebar->setItemDelegate(new SidebarDelegate(m_sidebar));
        m_sidebar->setSpacing(2);
        m_sidebar->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        const QStringList pages = {
            QStringLiteral("Overview"),
            QStringLiteral("Leftovers"),
            QStringLiteral("Stale Apps"),
            QStringLiteral("Outdated"),
            QStringLiteral("Packages"),
            QStringLiteral("Settings"),
        };
        for (const QString &p : pages) {
            auto *it = new QListWidgetItem(p);
            it->setData(Qt::UserRole, 0);
            m_sidebar->addItem(it);
        }
        m_sidebar->setCurrentRow(0);

        auto *right = new QWidget;
        auto *rv = new QVBoxLayout(right);
        rv->setContentsMargins(0, 0, 0, 0);
        rv->setSpacing(0);

        auto *tools = new QWidget;
        tools->setAutoFillBackground(true);
        {
            QPalette tp = tools->palette();
            tp.setColor(QPalette::Window, tp.color(QPalette::Button));
            tools->setPalette(tp);
        }
        auto *th = new QHBoxLayout(tools);
        th->setContentsMargins(16, 8, 16, 8);
        th->setSpacing(8);
        m_count = new QLabel;
        QFont small = smallFont();
        m_count->setFont(small);
        m_count->setForegroundRole(QPalette::PlaceholderText);
        m_search = new QLineEdit;
        m_search->setPlaceholderText(QStringLiteral("Search"));
        m_search->setFixedWidth(200);
        m_search->setFont(body);
        m_filter = new QComboBox;
        m_filter->addItem(QStringLiteral("All"), QStringLiteral("all"));
        m_filter->addItem(QStringLiteral("Leaves"), QStringLiteral("leaves"));
        m_filter->addItem(QStringLiteral("Globals"), QStringLiteral("globals"));
        m_filter->setFont(small);
        m_selectAll = new QPushButton(QStringLiteral("Select All"));
        m_rescan = new QPushButton(QStringLiteral("Rescan"));
        th->addWidget(m_count);
        th->addStretch();
        th->addWidget(m_search);
        th->addWidget(m_filter);
        th->addWidget(m_selectAll);
        th->addWidget(m_rescan);

        auto *toolsRule = new QFrame;
        toolsRule->setFrameShape(QFrame::HLine);
        toolsRule->setFrameShadow(QFrame::Plain);

        m_error = new QLabel;
        m_error->setFont(body);
        m_error->setContentsMargins(16, 8, 16, 8);
        m_error->hide();

        m_stack = new QStackedWidget;

        m_overview = buildOverview();
        m_stack->addWidget(m_overview);

        auto *listPage = new QWidget;
        auto *listSplit = new QSplitter(Qt::Horizontal, listPage);
        listSplit->setChildrenCollapsible(false);
        auto *listLay = new QHBoxLayout(listPage);
        listLay->setContentsMargins(0, 0, 0, 0);
        listLay->addWidget(listSplit);

        auto *listPane = new QWidget;
        auto *lpv = new QVBoxLayout(listPane);
        lpv->setContentsMargins(0, 0, 0, 0);
        lpv->setSpacing(0);
        m_table = new QTreeWidget;
        m_table->setRootIsDecorated(false);
        m_table->setUniformRowHeights(true);
        m_table->setItemsExpandable(true);
        m_table->setIndentation(0);
        m_table->setAlternatingRowColors(false);
        m_table->setSelectionMode(QAbstractItemView::SingleSelection);
        m_table->setSelectionBehavior(QAbstractItemView::SelectRows);
        m_table->setAllColumnsShowFocus(true);
        m_table->header()->setStretchLastSection(false);
        m_table->setFrameShape(QFrame::NoFrame);
        m_table->setItemDelegate(new TableRowDelegate(m_table));
        QFont head = small;
        head.setBold(true);
        m_table->header()->setFont(head);
        m_empty = new QLabel;
        m_empty->setAlignment(Qt::AlignCenter);
        m_empty->setWordWrap(true);
        m_empty->setFont(body);
        m_empty->setForegroundRole(QPalette::PlaceholderText);
        m_empty->setContentsMargins(16, 16, 16, 16);
        m_empty->hide();
        lpv->addWidget(m_table, 1);
        lpv->addWidget(m_empty);

        m_inspectorScroll = new QScrollArea;
        m_inspectorScroll->setWidgetResizable(true);
        m_inspectorScroll->setFrameShape(QFrame::NoFrame);
        m_inspectorScroll->setMinimumWidth(280);
        m_inspectorHost = new QWidget;
        m_inspectorLay = new QVBoxLayout(m_inspectorHost);
        m_inspectorLay->setContentsMargins(16, 16, 16, 16);
        m_inspectorLay->setSpacing(10);
        m_inspectorScroll->setWidget(m_inspectorHost);

        listSplit->addWidget(listPane);
        listSplit->addWidget(m_inspectorScroll);
        listSplit->setStretchFactor(0, 1);
        listSplit->setStretchFactor(1, 0);
        listSplit->setSizes({760, 320});
        m_stack->addWidget(listPage);

        m_settings = buildSettings();
        m_stack->addWidget(m_settings);

        m_actionBar = new QWidget;
        m_actionBar->setAutoFillBackground(true);
        {
            QPalette ap = m_actionBar->palette();
            ap.setColor(QPalette::Window, ap.color(QPalette::Button));
            m_actionBar->setPalette(ap);
        }
        auto *ah = new QHBoxLayout(m_actionBar);
        ah->setContentsMargins(12, 6, 12, 6);
        m_actionCount = new QLabel;
        m_actionCount->setFont(small);
        m_actionBytes = new QLabel;
        m_actionBytes->setFont(small);
        auto *clearSel = new QPushButton(QStringLiteral("Clear"));
        auto *preview = new QPushButton(QStringLiteral("Preview Script"));
        m_markManualBtn = new QPushButton(QStringLiteral("Mark Manual"));
        m_updateBtn = new QPushButton(QStringLiteral("Update"));
        m_deleteBtn = new QPushButton(QStringLiteral("Delete"));
        ah->addWidget(m_actionCount);
        ah->addWidget(m_actionBytes);
        ah->addStretch();
        ah->addWidget(clearSel);
        ah->addWidget(preview);
        ah->addWidget(m_markManualBtn);
        ah->addWidget(m_updateBtn);
        ah->addWidget(m_deleteBtn);
        m_actionBar->hide();

        rv->addWidget(tools);
        rv->addWidget(toolsRule);
        rv->addWidget(m_error);
        rv->addWidget(m_stack, 1);
        rv->addWidget(m_actionBar);

        outer->addWidget(m_sidebar);
        outer->addWidget(right);
        outer->setStretchFactor(0, 0);
        outer->setStretchFactor(1, 1);
        outer->setSizes({220, 960});
        setCentralWidget(outer);

        auto *scanMenu = menuBar()->addMenu(QStringLiteral("Scan"));
        auto *rescanAct = scanMenu->addAction(QStringLiteral("Rescan"));
        rescanAct->setShortcut(QKeySequence::Refresh);
        connect(rescanAct, &QAction::triggered, this, &MainWindow::rescan);
        auto *helpMenu = menuBar()->addMenu(QStringLiteral("Help"));
        auto *aboutAct = helpMenu->addAction(QStringLiteral("About AppAttic"));
        connect(aboutAct, &QAction::triggered, this, [this] {
            QMessageBox::about(
                this,
                QStringLiteral("AppAttic"),
                QStringLiteral("AppAttic 1.0.0\nLeftovers, stale apps, outdated packages.")
            );
        });

        connect(m_sidebar, &QListWidget::currentRowChanged, this, &MainWindow::showPage);
        connect(m_rescan, &QPushButton::clicked, this, &MainWindow::rescan);
        connect(m_search, &QLineEdit::textChanged, this, [this] { fillCurrent(); });
        connect(m_filter, &QComboBox::currentIndexChanged, this, [this] { fillCurrent(); });
        connect(m_selectAll, &QPushButton::clicked, this, &MainWindow::toggleSelectAll);
        connect(m_table, &QTreeWidget::currentItemChanged, this, [this](QTreeWidgetItem *cur, QTreeWidgetItem *) {
            m_selectedUid = cur ? cur->data(0, Qt::UserRole).toString() : QString();
            rebuildInspector();
        });
        connect(m_table, &QTreeWidget::itemClicked, this, [this](QTreeWidgetItem *it, int col) {
            if (!it || col != 0) return;
            const QString uid = it->data(0, Qt::UserRole).toString();
            if (uid.isEmpty() || it->data(0, Qt::UserRole + 1).isValid()) return;
            const Finding *f = findingByUid(uid);
            if (!f || !canMarkCleanup(*f, currentPage())) return;
            if (m_marked.contains(uid)) m_marked.remove(uid);
            else {
                m_marked.insert(uid);
                m_markedManual.remove(uid);
            }
            it->setText(0, m_marked.contains(uid) ? QStringLiteral("in") : QString());
            m_selectAll->setText(
                allMarked(currentPage(), visibleRows(currentPage()))
                    ? QStringLiteral("Deselect All")
                    : QStringLiteral("Select All")
            );
            rebuildInspector();
            refreshActionBar();
        });
        connect(clearSel, &QPushButton::clicked, this, [this] {
            m_marked.clear();
            m_markedManual.clear();
            fillCurrent();
            rebuildInspector();
            refreshActionBar();
        });
        connect(preview, &QPushButton::clicked, this, &MainWindow::previewScript);
        connect(m_deleteBtn, &QPushButton::clicked, this, &MainWindow::confirmDelete);
        connect(m_updateBtn, &QPushButton::clicked, this, &MainWindow::confirmUpdate);
        connect(m_markManualBtn, &QPushButton::clicked, this, &MainWindow::confirmMarkManual);

        loadSettings();
        applySystemAppearance();
        applyInitialPage();
        rescan();
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, [this](Qt::ColorScheme) {
            applySystemAppearance();
            fillCurrent();
        });
#endif
    }

    ~MainWindow() override {
        m_scanThread->quit();
        m_scanThread->wait(3000);
        delete m_worker;
    }

signals:
    void requestScan(const QString &core, const QStringList &pluginSpecs);

private slots:
    void showPage() {
        fillCurrent();
    }

    void rescan() {
        if (m_scanning) return;
        const QString out = coreOutDir();
        const QString core = out + QStringLiteral("/appattic_core.wasm");
        if (!QFileInfo::exists(core)) {
            m_findings.clear();
            m_scanOk = false;
            m_scanAt.clear();
            showError(QStringLiteral("WASM core missing. Run ./core/build.sh then Rescan."));
            fillCurrent();
            return;
        }
        const QStringList plugins = pluginWasmFiles(out);
        QStringList specs;
        for (const QString &p : plugins) {
            specs << (p + QLatin1Char('=') + QString::number(pluginTag(p)));
        }
        m_scanning = true;
        m_rescan->setEnabled(false);
        statusBar()->showMessage(QStringLiteral("Scanning"));
        emit requestScan(core, specs);
    }

    void scanFinished(const QByteArray &blobs, const QString &err, int rc) {
        m_scanning = false;
        m_rescan->setEnabled(true);
        m_findings.clear();
        for (const QByteArray &line : blobs.split('\n')) {
            if (line.isEmpty()) continue;
            parseBlob(line);
        }
        enrichFindingsUsageTiming(m_findings);
        m_scanOk = (rc == 0);
        m_scanAt = QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm"));
        if (rc != 0) {
            showError(err.isEmpty() ? QStringLiteral("WASM query failed") : err);
        } else {
            m_error->hide();
            statusBar()->showMessage(
                QStringLiteral("%1 plugin findings").arg(m_findings.size())
            );
        }
        fillCurrent();
    }

    void toggleSelectAll() {
        const Page page = currentPage();
        const QVector<Finding> rows = visibleRows(page);
        QStringList ids;
        for (const Finding &f : rows) {
            if (canMarkCleanup(f, page)) ids << f.uid();
        }
        if (ids.isEmpty()) return;
        bool allOn = true;
        for (const QString &id : ids) {
            if (!m_marked.contains(id)) {
                allOn = false;
                break;
            }
        }
        if (allOn) {
            for (const QString &id : ids) m_marked.remove(id);
        } else {
            for (const QString &id : ids) {
                m_marked.insert(id);
                m_markedManual.remove(id);
            }
        }
        fillTable(page);
        rebuildInspector();
        refreshActionBar();
    }

    void previewScript() {
        showScriptSheet(ScriptKind::Preview, previewAllScript(), QString(), QString());
    }

    void confirmDelete() {
        const QString script = cleanupScript();
        if (!scriptHasCommands(script)) return;
        if (m_confirmDelete) {
            showScriptSheet(
                ScriptKind::Delete,
                script,
                QStringLiteral("Delete %1 selected items? This runs the uninstall script now.")
                    .arg(cleanupMarkCount()),
                QStringLiteral("Delete")
            );
            return;
        }
        runScript(script);
    }

    void confirmUpdate() {
        const QString script = updateScript();
        if (!scriptHasCommands(script)) return;
        if (m_confirmDelete) {
            showScriptSheet(
                ScriptKind::Update,
                script,
                QStringLiteral("Update %1 selected packages?").arg(updateMarkCount()),
                QStringLiteral("Update")
            );
            return;
        }
        runScript(script);
    }

    void confirmMarkManual() {
        const QString script = markManualScript();
        if (!scriptHasCommands(script)) return;
        if (m_confirmDelete) {
            showScriptSheet(
                ScriptKind::MarkManual,
                script,
                QStringLiteral("Mark %1 packages as manually installed?").arg(m_markedManual.size()),
                QStringLiteral("Mark Manual")
            );
            return;
        }
        runScript(script);
    }

private:
    enum class ScriptKind { Preview, Delete, Update, MarkManual };

    void showScriptSheet(
        ScriptKind kind,
        const QString &script,
        const QString &question,
        const QString &runLabel
    ) {
        auto *dlg = new QDialog(this);
        dlg->setWindowModality(Qt::WindowModal);
        dlg->setWindowTitle(
            kind == ScriptKind::Preview ? QStringLiteral("Review Script") : QStringLiteral("Confirm")
        );
        dlg->resize(560, 420);
        auto *v = new QVBoxLayout(dlg);
        auto *title = new QLabel(
            question.isEmpty() ? QStringLiteral("Review every line before running.") : question
        );
        QFont body = bodyFont();
        title->setFont(body);
        title->setWordWrap(true);
        auto *hint = new QLabel(QStringLiteral("Review every line before running."));
        QFont small = smallFont();
        hint->setFont(small);
        hint->setForegroundRole(QPalette::PlaceholderText);
        hint->setVisible(!question.isEmpty());
        auto *edit = new QPlainTextEdit;
        QFont mono = smallFont();
        mono.setFamily(QStringLiteral("monospace"));
        edit->setFont(mono);
        edit->setReadOnly(true);
        edit->setPlainText(script);
        auto *box = new QDialogButtonBox;
        auto *copy = box->addButton(QStringLiteral("Copy"), QDialogButtonBox::ActionRole);
        connect(copy, &QPushButton::clicked, this, [script] {
            if (QClipboard *cb = QGuiApplication::clipboard()) cb->setText(script);
        });
        if (runLabel.isEmpty()) {
            box->addButton(QDialogButtonBox::Close);
            connect(box, &QDialogButtonBox::rejected, dlg, &QDialog::reject);
        } else {
            box->addButton(QStringLiteral("Cancel"), QDialogButtonBox::RejectRole);
            auto *go = box->addButton(runLabel, QDialogButtonBox::AcceptRole);
            Q_UNUSED(go);
            connect(box, &QDialogButtonBox::rejected, dlg, &QDialog::reject);
            connect(box, &QDialogButtonBox::accepted, dlg, &QDialog::accept);
        }
        v->addWidget(title);
        if (!question.isEmpty()) v->addWidget(hint);
        v->addWidget(edit, 1);
        v->addWidget(box);
        const int rc = dlg->exec();
        dlg->deleteLater();
        if (rc == QDialog::Accepted && !runLabel.isEmpty()) runScript(script);
    }
    Page currentPage() const {
        const int row = m_sidebar->currentRow();
        if (row < 0) return Page::Overview;
        return static_cast<Page>(row);
    }

    void applyInitialPage() {
        const QByteArray env = qgetenv("APPATTIC_PAGE");
        const QString v = QString::fromUtf8(env);
        int row = 0;
        if (v == QLatin1String("leftovers")) row = 1;
        else if (v == QLatin1String("stale")) row = 2;
        else if (v == QLatin1String("outdated")) row = 3;
        else if (v == QLatin1String("packages")) row = 4;
        else if (v == QLatin1String("settings")) row = 5;
        m_sidebar->setCurrentRow(row);
    }

    void showError(const QString &msg) {
        const Tone t = toneFrom(palette());
        QPalette p = m_error->palette();
        p.setColor(QPalette::WindowText, t.red);
        m_error->setPalette(p);
        m_error->setText(msg);
        m_error->show();
        statusBar()->showMessage(msg);
    }

    QWidget *buildOverview() {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(0, 0, 0, 0);
        v->setSpacing(0);
        auto *stats = new QWidget;
        auto *sh = new QHBoxLayout(stats);
        sh->setContentsMargins(16, 12, 16, 12);
        sh->setSpacing(28);
        m_statInstalled = addStat(sh, QStringLiteral("Installed"));
        m_statLeftovers = addStat(sh, QStringLiteral("Leftovers"));
        m_statLeftoverData = addStat(sh, QStringLiteral("Leftover data"));
        m_statStale = addStat(sh, QStringLiteral("Stale"));
        m_statOutdated = addStat(sh, QStringLiteral("Outdated"));
        m_statPackages = addStat(sh, QStringLiteral("Packages"));
        m_statScan = addStat(sh, QStringLiteral("Last scan"));
        sh->addStretch();
        v->addWidget(stats);

        auto *line = new QFrame;
        line->setFrameShape(QFrame::HLine);
        line->setFrameShadow(QFrame::Plain);
        v->addWidget(line);

        auto *cols = new QSplitter(Qt::Horizontal);
        cols->setChildrenCollapsible(false);
        m_ovLeftovers = makeOverviewTree(QStringLiteral("Largest leftovers"));
        m_ovStale = makeOverviewTree(QStringLiteral("Largest stale apps"));
        cols->addWidget(wrapOverviewCol(QStringLiteral("Largest leftovers"), m_ovLeftovers, &m_ovLeftEmpty));
        cols->addWidget(wrapOverviewCol(QStringLiteral("Largest stale apps"), m_ovStale, &m_ovStaleEmpty));
        cols->setStretchFactor(0, 1);
        cols->setStretchFactor(1, 1);
        cols->setSizes({580, 580});
        v->addWidget(cols, 1);
        connect(m_ovLeftovers, &QTreeWidget::itemClicked, this, [this](QTreeWidgetItem *it, int) {
            m_selectedUid = it->data(0, Qt::UserRole).toString();
            m_sidebar->setCurrentRow(int(Page::Leftovers));
        });
        connect(m_ovStale, &QTreeWidget::itemClicked, this, [this](QTreeWidgetItem *it, int) {
            m_selectedUid = it->data(0, Qt::UserRole).toString();
            m_sidebar->setCurrentRow(int(Page::Stale));
        });
        return w;
    }

    QLabel *addStat(QHBoxLayout *sh, const QString &label) {
        auto *box = new QWidget;
        auto *bv = new QVBoxLayout(box);
        bv->setContentsMargins(0, 0, 0, 0);
        bv->setSpacing(2);
        auto *l = new QLabel(label);
        l->setFont(smallFont());
        l->setForegroundRole(QPalette::PlaceholderText);
        auto *val = new QLabel(QStringLiteral("unknown"));
        val->setFont(bodyFont());
        bv->addWidget(l);
        bv->addWidget(val);
        sh->addWidget(box);
        return val;
    }

    QTreeWidget *makeOverviewTree(const QString &) {
        auto *t = new QTreeWidget;
        t->setRootIsDecorated(false);
        t->setUniformRowHeights(true);
        t->setIndentation(0);
        t->setHeaderLabels({QStringLiteral("Name"), QStringLiteral("What"), QStringLiteral("Size")});
        t->header()->setStretchLastSection(false);
        t->header()->setSectionResizeMode(0, QHeaderView::Stretch);
        t->header()->setSectionResizeMode(1, QHeaderView::Stretch);
        t->header()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
        t->setFrameShape(QFrame::NoFrame);
        QFont head = smallFont();
        head.setBold(true);
        t->header()->setFont(head);
        t->setItemDelegate(new TableRowDelegate(t));
        t->setColumnHidden(1, false);
        return t;
    }

    QWidget *wrapOverviewCol(const QString &title, QTreeWidget *tree, QLabel **emptyOut) {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(0, 0, 0, 0);
        v->setSpacing(0);
        auto *h = new QLabel(title);
        QFont f = bodyFont();
        f.setBold(true);
        h->setFont(f);
        h->setContentsMargins(16, 8, 16, 8);
        h->setAutoFillBackground(true);
        QPalette p = h->palette();
        p.setColor(QPalette::Window, p.color(QPalette::Button));
        h->setPalette(p);
        auto *empty = new QLabel;
        empty->setAlignment(Qt::AlignCenter);
        empty->setWordWrap(true);
        empty->setContentsMargins(16, 16, 16, 16);
        empty->setFont(bodyFont());
        empty->setForegroundRole(QPalette::PlaceholderText);
        v->addWidget(h);
        v->addWidget(tree, 1);
        v->addWidget(empty);
        *emptyOut = empty;
        return w;
    }

    QWidget *buildSettings() {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(16, 16, 16, 16);
        v->setSpacing(16);
        auto *row = new QHBoxLayout;
        row->setSpacing(32);

        auto scanCol = section(QStringLiteral("Scan"));
        m_includeSystem = new QCheckBox(QStringLiteral("Include system apps in scan"));
        auto *scanHint = hintLabel(
            QStringLiteral("Off by default. System apps are easy to misread as unused.")
        );
        scanCol.second->addWidget(m_includeSystem);
        scanCol.second->addWidget(scanHint);

        auto delCol = section(QStringLiteral("Deletion"));
        m_confirmBox = new QCheckBox(QStringLiteral("Confirm before running"));
        m_confirmBox->setChecked(true);
        auto *delHint = hintLabel(
            QStringLiteral("Shows an alert before rm, package remove, or updates.")
        );
        delCol.second->addWidget(m_confirmBox);
        delCol.second->addWidget(delHint);

        auto ignCol = section(QStringLiteral("Ignored leftovers"));
        m_ignoredList = new QLabel;
        m_ignoredList->setWordWrap(true);
        QFont small = smallFont();
        m_ignoredList->setFont(small);
        m_clearIgnored = new QPushButton(QStringLiteral("Clear ignored leftovers"));
        ignCol.second->addWidget(m_ignoredList);
        ignCol.second->addWidget(m_clearIgnored);

        row->addWidget(scanCol.first, 1);
        row->addWidget(delCol.first, 1);
        row->addWidget(ignCol.first, 1);
        v->addLayout(row);
        v->addStretch();
        auto *ver = new QLabel(QStringLiteral("AppAttic 1.0.0"));
        ver->setFont(small);
        ver->setForegroundRole(QPalette::PlaceholderText);
        v->addWidget(ver);

        connect(m_includeSystem, &QCheckBox::toggled, this, [this](bool on) {
            m_includeSystemOn = on;
            persistSettings();
        });
        connect(m_confirmBox, &QCheckBox::toggled, this, [this](bool on) {
            m_confirmDelete = on;
            persistSettings();
        });
        connect(m_clearIgnored, &QPushButton::clicked, this, [this] {
            m_ignored.clear();
            persistSettings();
            fillCurrent();
        });
        return w;
    }

    std::pair<QWidget *, QVBoxLayout *> section(const QString &title) {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        v->setContentsMargins(0, 0, 0, 0);
        v->setSpacing(8);
        auto *t = new QLabel(title);
        QFont f = bodyFont();
        f.setBold(true);
        t->setFont(f);
        v->addWidget(t);
        return {w, v};
    }

    QLabel *hintLabel(const QString &text) {
        auto *l = new QLabel(text);
        l->setFont(smallFont());
        l->setWordWrap(true);
        l->setForegroundRole(QPalette::PlaceholderText);
        return l;
    }

    void parseBlob(const QByteArray &line) {
        appendFindingsFromBlob(m_findings, line);
    }

    QVector<Finding> visibleRows(Page page) const {
        QVector<Finding> rows;
        const QString q = m_search->text().trimmed();
        const QString filt = m_filter->currentData().toString();
        for (const Finding &f : m_findings) {
            if (!matchPage(f, page)) continue;
            if (page == Page::Leftovers && leftoverIsIgnored(f, m_ignored)) continue;
            if (page == Page::Packages) {
                if (filt == QLatin1String("globals") && !isGlobalKind(f)) continue;
                if (filt == QLatin1String("leaves") && isGlobalKind(f)) continue;
            }
            if (!q.isEmpty()) {
                const QString hay = (
                    displayName(f) + f.path + f.kind + managerLabel(f)
                    + f.status + f.packagedPath + f.summary + f.reason
                    + f.extraPaths.join(QLatin1Char(' '))
                ).toLower();
                if (!hay.contains(q.toLower())) continue;
            }
            rows.push_back(f);
        }
        std::sort(rows.begin(), rows.end(), [](const Finding &a, const Finding &b) {
            return a.bytes > b.bytes;
        });
        return rows;
    }

    int countPage(Page page) const {
        int n = 0;
        for (const Finding &f : m_findings) {
            if (!matchPage(f, page)) continue;
            if (page == Page::Leftovers && leftoverIsIgnored(f, m_ignored)) continue;
            ++n;
        }
        return n;
    }

    void fillCurrent() {
        const Page page = currentPage();
        refreshSidebarCounts();
        const bool settings = page == Page::Settings;
        const bool overview = page == Page::Overview;
        m_stack->setCurrentIndex(settings ? 2 : (overview ? 0 : 1));
        const bool list = !settings && !overview;
        m_search->setVisible(list);
        m_filter->setVisible(page == Page::Packages);
        m_selectAll->setVisible(list);
        m_count->setVisible(list || overview);
        if (overview) fillOverview();
        else if (list) fillTable(page);
        else refreshIgnoredLabel();
        refreshActionBar();
    }

    void refreshSidebarCounts() {
        const int counts[] = {
            0,
            countPage(Page::Leftovers),
            countPage(Page::Stale),
            countPage(Page::Outdated),
            countPage(Page::Packages),
            0,
        };
        for (int i = 0; i < 6; ++i) {
            QListWidgetItem *it = m_sidebar->item(i);
            if (!it) continue;
            it->setData(Qt::UserRole, counts[i]);
        }
        m_sidebar->viewport()->update();
    }

    void fillOverview() {
        const Tone t = toneFrom(palette());
        const int leftovers = countPage(Page::Leftovers);
        const int stale = countPage(Page::Stale);
        const int outdated = countPage(Page::Outdated);
        const int packages = countPage(Page::Packages);
        qint64 leftoverBytes = 0;
        for (const Finding &f : m_findings) {
            if (isLeftover(f) && f.bytes > 0 && !leftoverIsIgnored(f, m_ignored)) leftoverBytes += f.bytes;
        }
        m_statInstalled->setText(QStringLiteral("unknown"));
        m_statLeftovers->setText(QString::number(leftovers));
        {
            QPalette p = m_statLeftovers->palette();
            p.setColor(QPalette::WindowText, leftovers ? t.red : t.text);
            m_statLeftovers->setPalette(p);
        }
        m_statLeftoverData->setText(
            leftoverBytes > 0 ? humanSize(leftoverBytes)
                              : (leftovers > 0 ? QStringLiteral("unknown") : humanSize(0))
        );
        m_statStale->setText(QString::number(stale));
        m_statOutdated->setText(QString::number(outdated));
        m_statPackages->setText(QString::number(packages));
        m_statScan->setText(m_scanAt.isEmpty() ? QStringLiteral("Never") : m_scanAt);

        auto fillOv = [&](QTreeWidget *tree, QLabel *empty, Page page, const QString &emptyText) {
            tree->clear();
            QVector<Finding> rows;
            for (const Finding &f : m_findings) {
            if (!matchPage(f, page)) continue;
            if (page == Page::Leftovers && leftoverIsIgnored(f, m_ignored)) continue;
                rows.push_back(f);
            }
            std::sort(rows.begin(), rows.end(), [](const Finding &a, const Finding &b) {
                return a.bytes > b.bytes;
            });
            const int n = qMin(12, rows.size());
            for (int i = 0; i < n; ++i) {
                const Finding &f = rows[i];
                auto *it = new QTreeWidgetItem(tree);
                it->setText(0, displayName(f));
                it->setText(1, whatText(f, page));
                it->setText(2, f.bytes >= 0 ? humanSize(f.bytes) : QStringLiteral("unknown"));
                it->setData(0, Qt::UserRole, f.uid());
                QFont body = bodyFont();
                QFont small = smallFont();
                it->setFont(0, body);
                it->setFont(1, small);
                it->setFont(2, small);
                it->setForeground(1, t.dim);
                it->setForeground(2, t.dim);
            }
            empty->setText(emptyText);
            empty->setVisible(n == 0);
        };
        fillOv(
            m_ovLeftovers,
            m_ovLeftEmpty,
            Page::Leftovers,
            QStringLiteral("No leftover data from uninstalled apps.")
        );
        fillOv(
            m_ovStale,
            m_ovStaleEmpty,
            Page::Stale,
            QStringLiteral("No unused installed apps in this scan.")
        );
        m_count->setText(QString());
    }

    void setupColumns(Page page) {
        m_table->setSortingEnabled(false);
        QStringList headers;
        switch (page) {
        case Page::Leftovers:
            headers = {QString(), QStringLiteral("Name"), QStringLiteral("Location"),
                       QStringLiteral("Modified"), QStringLiteral("Size")};
            break;
        case Page::Stale:
            headers = {QString(), QStringLiteral("Name"), QStringLiteral("Status"),
                       QStringLiteral("Last used"), QStringLiteral("Size")};
            break;
        case Page::Outdated:
            headers = {QString(), QStringLiteral("Name"), QStringLiteral("Manager"),
                       QStringLiteral("Current → Latest")};
            break;
        case Page::Packages:
            headers = {QString(), QStringLiteral("Name"), QStringLiteral("Manager"),
                       QStringLiteral("Kind"), QStringLiteral("Size")};
            break;
        default:
            headers = {QString(), QStringLiteral("Name")};
            break;
        }
        m_table->setColumnCount(headers.size());
        m_table->setHeaderLabels(headers);
        m_table->header()->setSectionResizeMode(0, QHeaderView::Fixed);
        m_table->setColumnWidth(0, 28);
        m_table->header()->setSectionResizeMode(1, QHeaderView::Stretch);
        for (int c = 2; c < headers.size(); ++c) {
            m_table->header()->setSectionResizeMode(c, QHeaderView::ResizeToContents);
        }
    }

    void fillTable(Page page) {
        setupColumns(page);
        const Tone t = toneFrom(palette());
        const QVector<Finding> rows = visibleRows(page);
        const QSignalBlocker block(m_table);
        m_table->clear();
        bool hasKids = false;
        for (const Finding &f : rows) {
            if (!f.children.isEmpty()) {
                hasKids = true;
                break;
            }
        }
        m_table->setRootIsDecorated(hasKids && page == Page::Packages);
        m_table->setIndentation(hasKids && page == Page::Packages ? 18 : 0);
        QFont body = bodyFont();
        QFont small = smallFont();
        QFont mark = small;
        mark.setBold(true);
        QTreeWidgetItem *select = nullptr;
        for (const Finding &f : rows) {
            auto *it = new QTreeWidgetItem(m_table);
            const QString uid = f.uid();
            it->setData(0, Qt::UserRole, uid);
            it->setFont(0, mark);
            it->setText(0, m_marked.contains(uid) ? QStringLiteral("in") : QString());
            it->setForeground(0, palette().color(QPalette::Highlight));
            it->setText(1, displayName(f));
            it->setFont(1, body);
            it->setSizeHint(0, QSize(28, rowPx()));
            switch (page) {
            case Page::Leftovers:
                it->setText(2, locationLabel(f));
                it->setText(3, modifiedLabel(f));
                it->setText(4, f.bytes >= 0 ? humanSize(f.bytes) : QStringLiteral("unknown"));
                it->setFont(2, small);
                it->setFont(3, small);
                it->setFont(4, small);
                it->setForeground(2, t.dim);
                it->setForeground(3, t.dim);
                it->setForeground(4, t.dim);
                if (isShadowFinding(f)) {
                    it->setForeground(1, t.amber);
                    it->setForeground(2, t.amber);
                }
                break;
            case Page::Stale:
                it->setText(2, statusLabel(f));
                it->setText(3, modifiedLabel(f));
                it->setText(4, f.bytes >= 0 ? humanSize(f.bytes) : QStringLiteral("unknown"));
                it->setFont(2, small);
                it->setFont(3, small);
                it->setFont(4, small);
                it->setForeground(2, statusColor(f, t, page));
                it->setForeground(3, t.dim);
                it->setForeground(4, t.dim);
                break;
            case Page::Outdated: {
                QString ver = QStringLiteral("-");
                if (!f.currentVersion.isEmpty() || !f.latestVersion.isEmpty()) {
                    ver = (f.currentVersion.isEmpty() ? QStringLiteral("-") : f.currentVersion)
                        + QStringLiteral(" → ") + (f.latestVersion.isEmpty() ? QStringLiteral("?") : f.latestVersion);
                }
                it->setText(2, managerLabel(f));
                it->setText(3, ver);
                it->setFont(2, small);
                it->setFont(3, small);
                it->setForeground(2, t.dim);
                it->setForeground(3, t.amber);
                break;
            }
            case Page::Packages:
                it->setText(2, managerLabel(f));
                it->setText(3, humanKind(f.kind));
                it->setText(4, f.bytes >= 0 ? humanSize(f.bytes) : QStringLiteral("unknown"));
                it->setFont(2, small);
                it->setFont(3, small);
                it->setFont(4, small);
                it->setForeground(2, t.dim);
                it->setForeground(3, statusColor(f, t, page));
                it->setForeground(4, t.dim);
                for (const QString &child : f.children) {
                    auto *kid = new QTreeWidgetItem(it);
                    kid->setText(1, child);
                    kid->setFont(1, small);
                    kid->setForeground(1, t.dim);
                    kid->setData(0, Qt::UserRole, uid);
                    kid->setData(0, Qt::UserRole + 1, child);
                    kid->setSizeHint(0, QSize(28, rowPx()));
                }
                break;
            default:
                break;
            }
            if (uid == m_selectedUid) select = it;
        }
        if (!select && m_table->topLevelItemCount() > 0) {
            select = m_table->topLevelItem(0);
            m_selectedUid = select->data(0, Qt::UserRole).toString();
        }
        if (select) m_table->setCurrentItem(select);
        else m_selectedUid.clear();

        m_empty->setText(emptyDetail(page));
        m_empty->setVisible(rows.isEmpty());
        QString count = countLabel(page, rows.size());
        if (!m_scanAt.isEmpty() && !m_scanning) {
            count += QStringLiteral(" · ") + m_scanAt;
        }
        m_count->setText(count);
        m_selectAll->setText(allMarked(page, rows) ? QStringLiteral("Deselect All") : QStringLiteral("Select All"));
        m_selectAll->setEnabled(!rows.isEmpty());
        rebuildInspector();
    }

    bool allMarked(Page page, const QVector<Finding> &rows) const {
        int n = 0;
        for (const Finding &f : rows) {
            if (!canMarkCleanup(f, page)) continue;
            if (!m_marked.contains(f.uid())) return false;
            ++n;
        }
        return n > 0;
    }

    QString countLabel(Page page, int n) const {
        switch (page) {
        case Page::Leftovers:
            return n == 1 ? QStringLiteral("1 leftover") : QString::number(n) + QStringLiteral(" leftovers");
        case Page::Stale:
            return n == 1 ? QStringLiteral("1 stale app") : QString::number(n) + QStringLiteral(" stale apps");
        case Page::Outdated:
            return n == 1 ? QStringLiteral("1 outdated package") : QString::number(n) + QStringLiteral(" outdated packages");
        case Page::Packages:
            return n == 1 ? QStringLiteral("1 package") : QString::number(n) + QStringLiteral(" packages");
        default:
            return QString::number(n);
        }
    }

    QString emptyDetail(Page page) const {
        if (!m_search->text().trimmed().isEmpty()) {
            return QStringLiteral("No items match this search.");
        }
        switch (page) {
        case Page::Leftovers: {
            QString body = QStringLiteral(
                "No leftover data from uninstalled apps, and no PATH or desktop overlays hiding package-manager files."
            );
            if (!m_ignored.isEmpty()) {
                const int n = m_ignored.size();
                body += QLatin1Char(' ')
                    + (n == 1 ? QStringLiteral("1 leftover path hidden from the list.")
                              : QString::number(n) + QStringLiteral(" leftover paths hidden from the list."));
            }
            return body;
        }
        case Page::Stale:
            return QStringLiteral(
                "No unused installed apps. Leftover dirs with last-used timing show here until the stale WASM plugin ships."
            );
        case Page::Outdated:
            return QStringLiteral(
                "No outdated packages. Brew, apt, pacman, dnf, and zypper stay empty when those tools are missing."
            );
        case Page::Packages:
            if (m_filter->currentData().toString() == QLatin1String("globals")) {
                return QStringLiteral("No user-global npm, pnpm, bun, pipx, or uv tools.");
            }
            if (m_filter->currentData().toString() == QLatin1String("leaves")) {
                return QStringLiteral("No distro orphans. apt/pacman/dnf/zypper reported nothing, or those tools are not installed.");
            }
            return QStringLiteral("No distro orphans or language globals. Missing managers stay empty; this page stays.");
        default:
            return QStringLiteral("No findings.");
        }
    }

    QString whatText(const Finding &f, Page page) const {
        if (isShadowFinding(f) && !f.packagedPath.isEmpty()) {
            if (!f.summary.isEmpty()
                && f.summary.contains(QLatin1String("hides the packaged"), Qt::CaseInsensitive)) {
                return f.summary;
            }
            const bool desktop = f.kind.contains(QLatin1String("desktop"));
            const QString overlay = desktop
                ? QStringLiteral("desktop overlay")
                : QStringLiteral("PATH overlay");
            const QString name = displayName(f);
            if (name.isEmpty() || name == QLatin1String("-")) {
                QString cap = overlay;
                cap[0] = cap[0].toUpper();
                return cap + QStringLiteral(". Hides the packaged ") + f.packagedPath + QLatin1Char('.');
            }
            return name + QStringLiteral(" is a ") + overlay
                + QStringLiteral(". Hides the packaged ") + f.packagedPath + QLatin1Char('.');
        }
        if (!f.summary.isEmpty()) return f.summary;
        if (page == Page::Packages) {
            return humanKind(f.kind) + QStringLiteral(" · ") + managerLabel(f);
        }
        if (!f.kind.isEmpty()) return humanKind(f.kind);
        return f.plugin;
    }

    QString whyText(const Finding &f) const {
        if (isShadowFinding(f) && !f.packagedPath.isEmpty()) {
            if (!f.reason.isEmpty()
                && f.reason.contains(QLatin1String("package-manager file"), Qt::CaseInsensitive)) {
                return f.reason;
            }
            if (f.kind.contains(QLatin1String("desktop"))) {
                return QStringLiteral("This .desktop file takes precedence over the package-manager file ")
                    + f.packagedPath + QLatin1Char('.');
            }
            return QStringLiteral("This file is earlier on PATH than the package-manager file ")
                + f.packagedPath + QLatin1Char('.');
        }
        if (!f.reason.isEmpty()) return f.reason;
        if (!f.dialogBody.isEmpty()) return f.dialogBody;
        return QStringLiteral("Flagged by the ") + f.plugin + QStringLiteral(" plugin.");
    }

    const Finding *findingByUid(const QString &uid) const {
        for (const Finding &f : m_findings) {
            if (f.uid() == uid) return &f;
        }
        return nullptr;
    }

    void clearInspector() {
        while (QLayoutItem *item = m_inspectorLay->takeAt(0)) {
            if (item->widget()) item->widget()->deleteLater();
            delete item;
        }
    }

    QLabel *inspectorLabel(const QString &text, int pt, bool bold, const QColor &color, bool mono = false) {
        auto *l = new QLabel(text);
        QFont f = font();
        f.setPointSize(pt);
        f.setBold(bold);
        if (mono) f.setFamily(QStringLiteral("monospace"));
        l->setFont(f);
        l->setWordWrap(true);
        l->setTextInteractionFlags(Qt::TextSelectableByMouse);
        QPalette p = l->palette();
        p.setColor(QPalette::WindowText, color);
        l->setPalette(p);
        return l;
    }

    void addFact(const QString &label, const QString &value, const QColor &color, bool mono = false) {
        auto *row = new QWidget;
        auto *h = new QHBoxLayout(row);
        h->setContentsMargins(0, 0, 0, 0);
        h->setSpacing(8);
        const Tone t = toneFrom(palette());
        auto *k = inspectorLabel(label, 11, false, t.dim);
        k->setFixedWidth(88);
        k->setAlignment(Qt::AlignRight | Qt::AlignTop);
        auto *v = inspectorLabel(value, mono ? 11 : 13, false, color, mono);
        h->addWidget(k);
        h->addWidget(v, 1);
        m_inspectorLay->addWidget(row);
    }

    void rebuildInspector() {
        clearInspector();
        const Page page = currentPage();
        const Tone t = toneFrom(palette());
        const Finding *f = findingByUid(m_selectedUid);
        if (page == Page::Overview || page == Page::Settings) return;
        if (!f || !matchPage(*f, page)) {
            QString title = QStringLiteral("Select an item");
            QString body = QStringLiteral("What it is, why it was flagged, plus path and size.");
            if (visibleRows(page).isEmpty()) {
                title = emptyTitle(page);
                body = emptyDetail(page);
            } else if (page == Page::Leftovers) {
                title = QStringLiteral("Select a leftover");
            } else if (page == Page::Stale) {
                title = QStringLiteral("Select an app");
            } else if (page == Page::Outdated) {
                title = QStringLiteral("Select a package");
                body = QStringLiteral("What it is, why it is listed, plus current and latest versions.");
            } else if (page == Page::Packages) {
                title = QStringLiteral("Select a package");
                body = QStringLiteral("Orphan distro packages and user-global language tools. Remove or mark-manual after confirm.");
            }
            m_inspectorLay->addWidget(inspectorLabel(title, 13, true, t.text));
            m_inspectorLay->addWidget(inspectorLabel(body, 13, false, t.dim));
            m_inspectorLay->addStretch();
            return;
        }
        m_inspectorLay->addWidget(inspectorLabel(displayName(*f), 13, true, t.text));
        addFact(QStringLiteral("What"), whatText(*f, page), t.text);
        addFact(QStringLiteral("Why"), whyText(*f), t.text);
        addFact(QStringLiteral("Kind"), f->kind.isEmpty() ? QStringLiteral("-") : f->kind, t.text);
        addFact(
            QStringLiteral("Status"),
            page == Page::Leftovers
                ? (f->status.isEmpty() ? QStringLiteral("-") : f->status)
                : statusLabel(*f),
            statusColor(*f, t, page)
        );
        if (!f->manager.isEmpty() || !f->engine.isEmpty()) {
            addFact(QStringLiteral("Manager"), managerLabel(*f), t.text);
        }
        if (!f->version.isEmpty()) addFact(QStringLiteral("Version"), f->version, t.text, true);
        if (!f->revision.isEmpty()) addFact(QStringLiteral("Revision"), f->revision, t.text, true);
        if (!f->currentVersion.isEmpty()) addFact(QStringLiteral("Current"), f->currentVersion, t.text, true);
        if (!f->latestVersion.isEmpty()) addFact(QStringLiteral("Latest"), f->latestVersion, t.amber, true);
        addFact(QStringLiteral("Size"), f->bytes >= 0 ? humanSize(f->bytes) : QStringLiteral("unknown"), t.text, true);
        addFact(QStringLiteral("Modified"), modifiedLabel(*f), t.text);
        if (page == Page::Leftovers) {
            addFact(QStringLiteral("Location"), locationLabel(*f), isShadowFinding(*f) ? t.amber : t.text);
        }
        if (!f->path.isEmpty()) addFact(QStringLiteral("Path"), f->path, t.text, true);
        if (!f->extraPaths.isEmpty()) {
            addFact(QStringLiteral("Also"), f->extraPaths.join(QLatin1Char('\n')), t.text, true);
        }
        if (!f->packagedPath.isEmpty()) {
            addFact(QStringLiteral("Shadows"), f->packagedPath, t.amber, true);
        }
        if (!f->children.isEmpty()) addFact(QStringLiteral("Depends"), f->children.join(QLatin1Char('\n')), t.text, true);

        m_inspectorLay->addStretch();

        if (canMarkCleanup(*f, page)) {
            auto *inc = new QCheckBox(
                page == Page::Outdated ? QStringLiteral("Include in update")
                                       : (page == Page::Packages ? QStringLiteral("Include in remove")
                                                                 : QStringLiteral("Include in cleanup"))
            );
            inc->setChecked(m_marked.contains(f->uid()));
            const QString uid = f->uid();
            connect(inc, &QCheckBox::toggled, this, [this, uid](bool on) {
                if (on) {
                    m_marked.insert(uid);
                    m_markedManual.remove(uid);
                } else {
                    m_marked.remove(uid);
                }
                for (int i = 0; i < m_table->topLevelItemCount(); ++i) {
                    QTreeWidgetItem *it = m_table->topLevelItem(i);
                    if (it->data(0, Qt::UserRole).toString() != uid) continue;
                    it->setText(0, on ? QStringLiteral("in") : QString());
                    break;
                }
                m_selectAll->setText(
                    allMarked(currentPage(), visibleRows(currentPage()))
                        ? QStringLiteral("Deselect All")
                        : QStringLiteral("Select All")
                );
                refreshActionBar();
            });
            m_inspectorLay->addWidget(inc);
        }
        if (page == Page::Packages && canMarkManual(*f)) {
            auto *keep = new QCheckBox(QStringLiteral("Mark as manually installed"));
            keep->setChecked(m_markedManual.contains(f->uid()));
            const QString uid = f->uid();
            connect(keep, &QCheckBox::toggled, this, [this, uid](bool on) {
                if (on) {
                    m_markedManual.insert(uid);
                    m_marked.remove(uid);
                    for (int i = 0; i < m_table->topLevelItemCount(); ++i) {
                        QTreeWidgetItem *it = m_table->topLevelItem(i);
                        if (it->data(0, Qt::UserRole).toString() != uid) continue;
                        it->setText(0, QString());
                        break;
                    }
                } else {
                    m_markedManual.remove(uid);
                }
                refreshActionBar();
            });
            m_inspectorLay->addWidget(keep);
        }
        if (!f->path.isEmpty()) {
            auto *reveal = new QPushButton(QStringLiteral("Show in Files"));
            const QString path = f->path;
            connect(reveal, &QPushButton::clicked, this, [path] {
                const QFileInfo fi(path);
                const QString dir = fi.isDir() ? path : fi.absolutePath();
                QDesktopServices::openUrl(QUrl::fromLocalFile(dir));
            });
            m_inspectorLay->addWidget(reveal);
        }
        if (page == Page::Leftovers) {
            auto *ign = new QPushButton(QStringLiteral("Ignore leftover"));
            const Finding copy = *f;
            connect(ign, &QPushButton::clicked, this, [this, copy] {
                for (const QString &k : leftoverIgnoreKeys(copy)) m_ignored.insert(k);
                m_marked.remove(copy.uid());
                persistSettings();
                m_selectedUid.clear();
                fillCurrent();
            });
            m_inspectorLay->addWidget(ign);
        }
    }

    QString emptyTitle(Page page) const {
        switch (page) {
        case Page::Leftovers:
            return QStringLiteral("No leftover data");
        case Page::Stale:
            return QStringLiteral("No stale apps");
        case Page::Outdated:
            return QStringLiteral("No outdated packages");
        case Page::Packages:
            return QStringLiteral("No unused packages");
        default:
            return QStringLiteral("Nothing to review");
        }
    }

    void refreshActionBar() {
        qint64 bytes = 0;
        int n = 0;
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid()) && !m_markedManual.contains(f.uid())) continue;
            ++n;
            if (f.bytes > 0) bytes += f.bytes;
        }
        m_actionBar->setVisible(n > 0);
        m_actionCount->setText(QStringLiteral("%1 selected").arg(n));
        m_actionBytes->setText(bytes > 0 ? humanSize(bytes) : QString());
        const bool canDelete = scriptHasCommands(cleanupScript());
        const bool canUpdate = scriptHasCommands(updateScript());
        const bool canKeep = scriptHasCommands(markManualScript());
        m_deleteBtn->setVisible(canDelete);
        m_deleteBtn->setEnabled(canDelete);
        m_updateBtn->setVisible(canUpdate);
        m_updateBtn->setEnabled(canUpdate);
        m_markManualBtn->setVisible(canKeep);
        m_markManualBtn->setEnabled(canKeep);
    }

    int cleanupMarkCount() const {
        int n = 0;
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid())) continue;
            if (isOutdated(f) && !isLeftover(f) && !isStale(f) && !isPackage(f)) continue;
            ++n;
        }
        return n;
    }

    int updateMarkCount() const {
        int n = 0;
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid()) || !isOutdated(f)) continue;
            ++n;
        }
        return n;
    }

    QString cleanupScript() const {
        QStringList lines;
        lines << QStringLiteral("#!/bin/sh") << QStringLiteral("set -e")
              << QStringLiteral("# AppAttic. Review before running.");
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid())) continue;
            if (isOutdated(f) && !isLeftover(f) && !isStale(f) && !isPackage(f)) continue;
            const QString cmd = isLeftover(f) ? leftoverCleanupCommand(f) : f.command;
            if (cmd.isEmpty()) continue;
            lines << cmd;
        }
        return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
    }

    QString updateScript() const {
        QStringList lines;
        lines << QStringLiteral("#!/bin/sh") << QStringLiteral("set -e")
              << QStringLiteral("# AppAttic. Review before running.");
        for (const Finding &f : m_findings) {
            if (!m_marked.contains(f.uid()) || !isOutdated(f)) continue;
            const QString cmd = f.updateCommand.isEmpty() ? f.command : f.updateCommand;
            if (cmd.isEmpty()) continue;
            lines << cmd;
        }
        return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
    }

    QString markManualScript() const {
        QStringList lines;
        lines << QStringLiteral("#!/bin/sh") << QStringLiteral("set -e")
              << QStringLiteral("# AppAttic. Review before running.")
              << QStringLiteral("# Mark as manually installed (keep)");
        for (const Finding &f : m_findings) {
            if (!m_markedManual.contains(f.uid())) continue;
            const QString cmd = markManualCommand(f);
            if (cmd.isEmpty()) continue;
            lines << cmd;
        }
        return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
    }

    QString previewAllScript() const {
        QString out = cleanupScript();
        if (scriptHasCommands(updateScript())) {
            out += QStringLiteral("\n# Update selected packages\n");
            for (const QString &line : updateScript().split(QLatin1Char('\n'))) {
                const QString t = line.trimmed();
                if (t.isEmpty() || t.startsWith(QLatin1Char('#')) || t == QLatin1String("#!/bin/sh")
                    || t.startsWith(QLatin1String("set "))) {
                    continue;
                }
                out += line + QLatin1Char('\n');
            }
        }
        if (scriptHasCommands(markManualScript())) {
            out += QStringLiteral("\n# Mark as manually installed. Delete in the UI does not run these lines.\n");
            for (const QString &line : markManualScript().split(QLatin1Char('\n'))) {
                const QString t = line.trimmed();
                if (t.isEmpty() || t.startsWith(QLatin1Char('#')) || t == QLatin1String("#!/bin/sh")
                    || t.startsWith(QLatin1String("set "))) {
                    continue;
                }
                out += line + QLatin1Char('\n');
            }
        }
        return out;
    }

    void runScript(const QString &script) {
        QTemporaryFile tmp(QDir::temp().filePath(QStringLiteral("appattic-XXXXXX.sh")));
        tmp.setAutoRemove(false);
        if (!tmp.open()) {
            showError(QStringLiteral("Could not write preview script."));
            return;
        }
        tmp.write(script.toUtf8());
        tmp.close();
        QFile::setPermissions(tmp.fileName(), QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        auto *proc = new QProcess(this);
        connect(proc, &QProcess::finished, this, [this, proc, path = tmp.fileName()](int code) {
            QFile::remove(path);
            if (code != 0) {
                showError(QString::fromUtf8(proc->readAllStandardError()));
            } else {
                m_error->hide();
                statusBar()->showMessage(QStringLiteral("Cleanup script finished"));
                m_marked.clear();
                m_markedManual.clear();
                rescan();
            }
            proc->deleteLater();
        });
        proc->start(QStringLiteral("/bin/sh"), {tmp.fileName()});
    }

    void applySystemAppearance() {
        if (!m_table || m_applyingAppearance) return;
        m_applyingAppearance = true;
        resetWidgetPalette(m_table);
        resetWidgetPalette(m_inspectorHost);
        resetWidgetPalette(m_inspectorScroll);
        resetWidgetPalette(m_empty);
        resetWidgetPalette(m_ovLeftovers);
        resetWidgetPalette(m_ovStale);
        if (m_sidebar) m_sidebar->setAutoFillBackground(false);
        m_applyingAppearance = false;
    }

    void changeEvent(QEvent *e) override {
        QMainWindow::changeEvent(e);
        if (!e) return;
        if (e->type() == QEvent::PaletteChange || e->type() == QEvent::ApplicationPaletteChange
            || e->type() == QEvent::StyleChange) {
            applySystemAppearance();
            if (m_table) fillCurrent();
        }
    }

    void loadSettings() {
        QSettings s(QStringLiteral("AppAttic"), QStringLiteral("AppAttic"));
        m_confirmDelete = s.value(QStringLiteral("confirmDelete"), true).toBool();
        m_includeSystemOn = s.value(QStringLiteral("includeSystem"), false).toBool();
        const QStringList ign = s.value(QStringLiteral("ignoredLeftovers")).toStringList();
        m_ignored = QSet<QString>(ign.begin(), ign.end());
        m_confirmBox->setChecked(m_confirmDelete);
        m_includeSystem->setChecked(m_includeSystemOn);
        refreshIgnoredLabel();
    }

    void persistSettings() {
        QSettings s(QStringLiteral("AppAttic"), QStringLiteral("AppAttic"));
        s.setValue(QStringLiteral("confirmDelete"), m_confirmDelete);
        s.setValue(QStringLiteral("includeSystem"), m_includeSystemOn);
        s.setValue(QStringLiteral("ignoredLeftovers"), QStringList(m_ignored.begin(), m_ignored.end()));
        refreshIgnoredLabel();
    }

    void refreshIgnoredLabel() {
        if (!m_ignoredList) return;
        if (m_ignored.isEmpty()) {
            m_ignoredList->setText(
                QStringLiteral("None. Ignore a leftover from its inspector to hide it on later scans.")
            );
            m_clearIgnored->setEnabled(false);
            return;
        }
        QStringList names;
        for (const QString &p : m_ignored) names << QFileInfo(p).fileName();
        names.sort();
        m_ignoredList->setText(
            QString::number(m_ignored.size()) + QStringLiteral(" leftover paths hidden from the list.\n")
            + names.mid(0, 12).join(QLatin1Char('\n'))
        );
        m_clearIgnored->setEnabled(true);
    }

    QListWidget *m_sidebar = nullptr;
    QStackedWidget *m_stack = nullptr;
    QWidget *m_overview = nullptr;
    QWidget *m_settings = nullptr;
    QTreeWidget *m_table = nullptr;
    QLabel *m_empty = nullptr;
    QScrollArea *m_inspectorScroll = nullptr;
    QWidget *m_inspectorHost = nullptr;
    QVBoxLayout *m_inspectorLay = nullptr;
    QLabel *m_count = nullptr;
    QLabel *m_error = nullptr;
    QLineEdit *m_search = nullptr;
    QComboBox *m_filter = nullptr;
    QPushButton *m_selectAll = nullptr;
    QPushButton *m_rescan = nullptr;
    QWidget *m_actionBar = nullptr;
    QLabel *m_actionCount = nullptr;
    QLabel *m_actionBytes = nullptr;
    QPushButton *m_deleteBtn = nullptr;
    QPushButton *m_updateBtn = nullptr;
    QPushButton *m_markManualBtn = nullptr;
    QCheckBox *m_includeSystem = nullptr;
    QCheckBox *m_confirmBox = nullptr;
    QLabel *m_ignoredList = nullptr;
    QPushButton *m_clearIgnored = nullptr;
    QLabel *m_statInstalled = nullptr;
    QLabel *m_statLeftovers = nullptr;
    QLabel *m_statLeftoverData = nullptr;
    QLabel *m_statStale = nullptr;
    QLabel *m_statOutdated = nullptr;
    QLabel *m_statPackages = nullptr;
    QLabel *m_statScan = nullptr;
    QTreeWidget *m_ovLeftovers = nullptr;
    QTreeWidget *m_ovStale = nullptr;
    QLabel *m_ovLeftEmpty = nullptr;
    QLabel *m_ovStaleEmpty = nullptr;
    QThread *m_scanThread = nullptr;
    ScanWorker *m_worker = nullptr;
    QVector<Finding> m_findings;
    QSet<QString> m_marked;
    QSet<QString> m_markedManual;
    QSet<QString> m_ignored;
    QString m_selectedUid;
    QString m_scanAt;
    bool m_scanning = false;
    bool m_scanOk = false;
    bool m_confirmDelete = true;
    bool m_includeSystemOn = false;
    bool m_applyingAppearance = false;
};

static bool argvHas(int argc, char **argv, const char *flag) {
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], flag) == 0) return true;
    }
    return false;
}

struct SmokeState {
    int plugins = 0;
    bool path_shadow_plugin = false;
    int path_shadow_findings = 0;
    bool leftover_path_plugin = false;
    bool path_home_dot_active = false;
    bool flatpak_plugin = false;
    int flatpak_unused_runtime = 0;
    int raw_outdated_kind = 0;
    QVector<Finding> findings;
};

static void smokeCollectJson(const char *json, size_t len, void *user) {
    auto *st = static_cast<SmokeState *>(user);
    st->plugins += 1;
    const QByteArray line(json, int(len));
    appendFindingsFromBlob(st->findings, line);

    const QJsonDocument doc = QJsonDocument::fromJson(line);
    if (!doc.isObject()) return;
    const QJsonObject obj = doc.object();
    const QString plugin = obj.value(QStringLiteral("plugin")).toString();
    const QJsonArray arr = obj.value(QStringLiteral("findings")).toArray();
    const int n = arr.size();

    if (plugin == QLatin1String("path-shadow")) {
        st->path_shadow_plugin = true;
        st->path_shadow_findings = n;
    }
    if (plugin.startsWith(QLatin1String("path-"))) {
        st->leftover_path_plugin = true;
    }
    if (plugin == QLatin1String("path-home-dot") && n > 0) {
        st->path_home_dot_active = true;
    }
    if (plugin == QLatin1String("flatpak")) {
        st->flatpak_plugin = true;
        for (const QJsonValue &v : arr) {
            const QJsonObject f = v.toObject();
            if (jsonStr(f, "kind") == QLatin1String("unused-runtime")) {
                st->flatpak_unused_runtime += 1;
            }
        }
    }
    for (const QJsonValue &v : arr) {
        const QJsonObject f = v.toObject();
        const QString kind = jsonStr(f, "kind");
        if (kind.contains(QLatin1String("outdated")) || kind.contains(QLatin1String("upgrade"))) {
            st->raw_outdated_kind += 1;
        }
    }
}

static int smokeVerifyTables(const SmokeState &st) {
    const QVector<Finding> &findings = st.findings;
    if (findings.isEmpty()) {
        std::fprintf(stderr, "tables: no findings parsed from plugin JSON\n");
        return 1;
    }

    const int leftovers = countPageRows(findings, Page::Leftovers);
    const int stale = countPageRows(findings, Page::Stale);
    const int outdated = countPageRows(findings, Page::Outdated);
    const int packages = countPageRows(findings, Page::Packages);

    int pathLeftovers = 0;
    bool hasMozilla = false;
    bool hasWine = false;
    int shadowLeftovers = 0;
    int flatpakUnusedAsPackage = 0;

    for (const Finding &f : findings) {
        if (f.plugin.startsWith(QLatin1String("path-")) && isLeftover(f)) {
            ++pathLeftovers;
            if (f.path.contains(QLatin1String(".mozilla"))) hasMozilla = true;
            if (f.path.contains(QLatin1String(".wine"))) hasWine = true;
        }
        if (f.plugin == QLatin1String("path-shadow") && isLeftover(f)) {
            ++shadowLeftovers;
        }
        if (f.plugin == QLatin1String("flatpak") && f.kind == QLatin1String("unused-runtime")) {
            if (!isPackage(f)) {
                std::fprintf(stderr,
                    "tables: flatpak unused-runtime not classified as package (%s)\n",
                    f.id.toUtf8().constData());
                return 1;
            }
            ++flatpakUnusedAsPackage;
        }
        if (isLeftover(f) && !matchPage(f, Page::Leftovers)) {
            std::fprintf(stderr, "tables: leftover finding not in Leftovers table\n");
            return 1;
        }
        if (isOutdated(f) && !matchPage(f, Page::Outdated)) {
            std::fprintf(stderr, "tables: outdated finding not in Outdated table\n");
            return 1;
        }
        if (isPackage(f) && !matchPage(f, Page::Packages)) {
            std::fprintf(stderr, "tables: package finding not in Packages table\n");
            return 1;
        }
        if (isStale(f) && !matchPage(f, Page::Stale)) {
            std::fprintf(stderr, "tables: stale finding not in Stale table\n");
            return 1;
        }
    }

    if (pathLeftovers < 1) {
        std::fprintf(stderr, "tables: no path-* leftover findings (classifier/ingest broken)\n");
        return 1;
    }
    if (st.path_home_dot_active) {
        if (!hasMozilla || !hasWine) {
            std::fprintf(stderr,
                "tables: path-home-dot active but missing .mozilla/.wine fixture paths\n");
            return 1;
        }
        if (stale < 1) {
            std::fprintf(stderr,
                "tables: path-home-dot leftovers with timing not classified as stale\n");
            return 1;
        }
    }
    // path-shadow: only assert when plugin returned findings (tag 1 / overlay dirs present).
    if (st.path_shadow_findings > 0 && shadowLeftovers < 1) {
        std::fprintf(stderr, "tables: path-shadow findings not classified as leftovers\n");
        return 1;
    }
    // Outdated: only assert when fixtures emitted outdated-kind rows.
    if (st.raw_outdated_kind > 0 && outdated < 1) {
        std::fprintf(stderr, "tables: outdated fixture rows not classified as outdated\n");
        return 1;
    }
    // flatpak unused-runtime: only assert when flatpak plugin returned them.
    if (st.flatpak_unused_runtime > 0 && flatpakUnusedAsPackage < st.flatpak_unused_runtime) {
        std::fprintf(stderr, "tables: flatpak unused-runtime not routed to Packages\n");
        return 1;
    }

    std::fprintf(stdout, "tables: ok (leftovers=%d stale=%d outdated=%d packages=%d)\n",
        leftovers, stale, outdated, packages);
    return 0;
}

static int runVersion(int argc, char **argv) {
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")
        && qEnvironmentVariableIsEmpty("DISPLAY")
        && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY")) {
        qputenv("QT_QPA_PLATFORM", "offscreen");
    }
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("AppAttic"));
    QApplication::setOrganizationName(QStringLiteral("AppAttic"));
    std::fprintf(stdout, "AppAttic 1.0.0\n");
    std::fprintf(stdout, "Qt %s\n", qVersion());
    const QString out = coreOutDir();
    const QString core = out + QStringLiteral("/appattic_core.wasm");
    if (!QFileInfo::exists(core)) {
        std::fprintf(stdout, "wasm: core missing (%s)\n", core.toUtf8().constData());
    } else {
        std::fprintf(stdout, "wasm: core present\n");
    }
    return 0;
}

static int runSmoke(int argc, char **argv) {
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")
        && qEnvironmentVariableIsEmpty("DISPLAY")
        && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY")) {
        qputenv("QT_QPA_PLATFORM", "offscreen");
    }
    qputenv("APPATTIC_HOST_EXEC_FIXTURE", "1");
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("AppAttic"));
    QApplication::setOrganizationName(QStringLiteral("AppAttic"));
    std::fprintf(stdout, "AppAttic 1.0.0\n");
    std::fprintf(stdout, "Qt %s\n", qVersion());

    const QString out = coreOutDir();
    const QString core = out + QStringLiteral("/appattic_core.wasm");
    if (!QFileInfo::exists(core)) {
        std::fprintf(stderr, "wasm: core missing (%s)\n", core.toUtf8().constData());
        std::fprintf(stderr, "build with: bash core/build.sh\n");
        return 1;
    }
    const QStringList plugins = pluginWasmFiles(out);
    int wasm_on_disk = 0;
    for (const QString &p : plugins) {
        if (QFileInfo::exists(p)) ++wasm_on_disk;
    }
    if (wasm_on_disk < 5) {
        std::fprintf(stderr, "wasm: too few plugin modules on disk (%d/%d)\n",
            wasm_on_disk, plugins.size());
        return 1;
    }
    QStringList specs;
    for (const QString &p : plugins) {
        specs << (p + QLatin1Char('=') + QString::number(pluginTag(p)));
    }
    std::vector<QByteArray> specBytes;
    std::vector<char *> ptrs;
    specBytes.reserve(size_t(specs.size()));
    ptrs.reserve(size_t(specs.size()));
    for (const QString &s : specs) specBytes.push_back(s.toUtf8());
    for (QByteArray &s : specBytes) ptrs.push_back(s.data());
    SmokeState st;
    char err[1024];
    err[0] = '\0';
    const QByteArray coreUtf8 = core.toUtf8();
    const int rc = appattic_wasm_run(
        coreUtf8.constData(),
        ptrs.empty() ? nullptr : ptrs.data(),
        int(ptrs.size()),
        smokeCollectJson,
        &st,
        err,
        sizeof err
    );
    if (rc != 0) {
        std::fprintf(stderr, "wasm query failed: %s\n", err[0] ? err : "(no detail)");
        return 1;
    }
    if (st.plugins < 1) {
        std::fprintf(stderr, "wasm: no plugin JSON returned\n");
        return 1;
    }
    if (!st.path_shadow_plugin) {
        std::fprintf(stderr, "wasm: path-shadow plugin missing from scan output\n");
        return 1;
    }
    if (!st.leftover_path_plugin) {
        std::fprintf(stderr, "wasm: no path-* leftover plugin JSON returned\n");
        return 1;
    }
    if (smokeVerifyTables(st) != 0) {
        return 1;
    }
    std::fprintf(stdout, "plugin:path-shadow\n");
    std::fprintf(stdout, "wasm: ok (%d plugins)\n", st.plugins);
    std::fprintf(stdout, "SMOKE=ok\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argvHas(argc, argv, "--version")) {
        return runVersion(argc, argv);
    }
    if (argvHas(argc, argv, "--smoke")) {
        return runSmoke(argc, argv);
    }
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("AppAttic"));
    QApplication::setOrganizationName(QStringLiteral("AppAttic"));
    MainWindow w;
    w.show();
    return app.exec();
}

#include "main.moc"
