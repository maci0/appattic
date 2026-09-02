#include "finding.h"

#include <QDate>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileDevice>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QRegularExpression>
#include <QTimeZone>

#include <initializer_list>

static qint64 jsonInt(const QJsonObject &o, const char *key) {
    const QJsonValue v = o.value(QLatin1String(key));
    if (v.isDouble()) return qint64(v.toDouble());
    if (v.isString()) return v.toString().toLongLong();
    return -1;
}

QString jsonStr(const QJsonObject &o, const char *key) {
    const QJsonValue v = o.value(QLatin1String(key));
    if (v.isString()) return v.toString();
    if (v.isDouble()) return QString::number(v.toDouble(), 'f', 0);
    return {};
}

QString pathIdentityKey(const QString &path) {
    return path.normalized(QString::NormalizationForm_C);
}

QString redactHomePaths(const QString &text, const QString &home) {
    const QString homePath = QDir::cleanPath(home.isEmpty() ? QDir::homePath() : home);
    if (homePath.size() <= 1) return text;
    const QRegularExpression re(
        QRegularExpression::escape(homePath) + QStringLiteral("(?=/|$|[\\s:\"',;])"));
    QString out = text;
    out.replace(re, QStringLiteral("~"));
    return out;
}

bool restrictOwnerOnlyFile(const QString &path) {
    return QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}

bool restrictOwnerOnlyDir(const QString &path) {
    return QFile::setPermissions(
        path,
        QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
}

void restrictPrivateDataFile(const QString &path) {
    restrictOwnerOnlyFile(path);
    const QString dir = QFileInfo(path).absolutePath();
    if (QFileInfo(dir).fileName().compare(QStringLiteral("appattic"), Qt::CaseInsensitive) == 0) {
        restrictOwnerOnlyDir(dir);
    }
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

bool outdatedIsUpdatable(const QString &manager, const QString &kind) {
    if (kind == QLatin1String("untrusted") || kind.contains(QLatin1String("untrusted"))) {
        return false;
    }
    return manager == QLatin1String("brew-formula")
        || manager == QLatin1String("brew-cask")
        || manager == QLatin1String("flatpak");
}

static bool findingIsUntrusted(const Finding &row) {
    return row.kind == QLatin1String("untrusted")
        || row.kind.contains(QLatin1String("untrusted"))
        || row.status == QLatin1String("untrusted");
}

/// Honor explicit `updatable`. Do not treat leftover/outdated `status` as a live-upgrade flag.
static bool parseUpdatable(const QJsonObject &f, const Finding &row) {
    if (findingIsUntrusted(row)) return false;
    if (f.contains(QLatin1String("updatable"))) return jsonBool(f, "updatable");
    const QJsonValue upd = f.value(QLatin1String("update"));
    if (upd.isBool()) return upd.toBool();
    return outdatedIsUpdatable(row.manager, row.kind);
}

QString shellQuote(const QString &s) {
    QString q = s;
    q.replace(QLatin1Char('\''), QStringLiteral("'\\''"));
    return QLatin1Char('\'') + q + QLatin1Char('\'');
}

bool scriptHasCommands(const QString &script) {
    const QStringList lines = script.split(QLatin1Char('\n'));
    for (const QString &raw : lines) {
        const QString t = raw.trimmed();
        if (t.isEmpty() || t.startsWith(QLatin1Char('#'))) continue;
        if (t == QLatin1String("set -e") || t.startsWith(QLatin1String("set -"))) continue;
        return true;
    }
    return false;
}

QString humanSize(qint64 bytes) {
    if (bytes < 0) return QStringLiteral("unknown");
    double n = double(bytes);
    static const char *units[] = {"B", "KB", "MB", "GB", "TB", "PB"};
    const int last = int(sizeof(units) / sizeof(units[0])) - 1;
    int unit = 0;
    while (unit < last) {
        if (qAbs(n) < 1024.0) {
            if (qRound(qAbs(n) * 10.0) / 10.0 >= 1024.0) {
                n /= 1024.0;
                unit += 1;
                continue;
            }
            if (unit == 0) return QString::number(bytes) + QStringLiteral(" B");
            return QString::number(n, 'f', 1) + QLatin1Char(' ') + QLatin1String(units[unit]);
        }
        n /= 1024.0;
        unit += 1;
    }
    return QString::number(n, 'f', 1) + QLatin1Char(' ') + QLatin1String(units[unit]);
}

QString humanKind(const QString &kind) {
    if (kind == QLatin1String("global")) return QStringLiteral("Global");
    if (kind == QLatin1String("orphan") || kind.contains(QLatin1String("orphan"))) {
        return QStringLiteral("Orphan");
    }
    QString s = kind;
    s.replace(QLatin1Char('-'), QLatin1Char(' '));
    if (!s.isEmpty()) s[0] = s[0].toUpper();
    return s.isEmpty() ? QStringLiteral("-") : s;
}

QString managerLabel(const Finding &f) {
    QString m = f.manager;
    if (m.isEmpty()) m = f.engine;
    if (m.isEmpty()) m = f.plugin;
    m.replace(QLatin1Char('-'), QLatin1Char(' '));
    return m;
}

QString locationLabel(const Finding &f) {
    if (!f.rootLabel.isEmpty()) return f.rootLabel;
    if (f.path.isEmpty()) return QStringLiteral("-");
    const QFileInfo fi(f.path);
    const QString parent = fi.dir().dirName();
    return parent.isEmpty() ? f.path : parent;
}

/// Instant from RFC 3339 / ISO-8601. Zone-less values are UTC, matching parseISODate.
/// Date-only `yyyy-MM-dd` is that calendar day in local time (not UTC midnight).
QDateTime parseIsoInstant(const QString &value) {
    QString s = value.trimmed();
    if (s.isEmpty()) return {};
    if (s.endsWith(QLatin1Char('z'))) s[s.size() - 1] = QLatin1Char('Z');

    if (s.size() == 10 && s[4] == QLatin1Char('-') && s[7] == QLatin1Char('-')) {
        const QDate d = QDate::fromString(s, Qt::ISODate);
        if (d.isValid()) return d.startOfDay();
    }

    const int tIndex = s.indexOf(QLatin1Char('T'));
    if (tIndex >= 0) {
        const int dot = s.indexOf(QLatin1Char('.'), tIndex);
        if (dot >= 0) {
            int digitEnd = dot + 1;
            int count = 0;
            while (digitEnd < s.size() && s.at(digitEnd).isDigit()) {
                ++count;
                ++digitEnd;
            }
            if (count > 3) {
                s = s.left(dot + 1 + 3) + s.mid(digitEnd);
            }
        }
    }

    QDateTime dt = QDateTime::fromString(s, Qt::ISODateWithMs);
    if (!dt.isValid()) dt = QDateTime::fromString(s, Qt::ISODate);
    if (!dt.isValid()) {
        static const char *kFmts[] = {
            "yyyy-MM-dd HH:mm:ss t",
            "yyyy-MM-ddTHH:mm:ss t",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-ddTHH:mm:ss",
        };
        for (const char *fmt : kFmts) {
            dt = QDateTime::fromString(s, QLatin1String(fmt));
            if (dt.isValid()) break;
        }
    }
    if (!dt.isValid()) return {};
    if (dt.timeSpec() == Qt::LocalTime) {
        dt = QDateTime(dt.date(), dt.time(), QTimeZone::utc());
    }
    return dt;
}

static qint64 localCalendarDaysSince(const QDateTime &instant, const QDateTime &now) {
    if (!instant.isValid() || !now.isValid()) return -1;
    return instant.toLocalTime().date().daysTo(now.toLocalTime().date());
}

static QString relativeDayLabel(qint64 days) {
    if (days <= 0) return QStringLiteral("Today");
    if (days == 1) return QStringLiteral("Yesterday");
    if (days < 45) return QString::number(days) + QStringLiteral(" days ago");
    return {};
}

QString modifiedLabel(const Finding &f, const QDateTime &now) {
    QDateTime instant;
    if (!f.mtime.isEmpty()) instant = parseIsoInstant(f.mtime);
    if (!instant.isValid() && !f.lastUsed.isEmpty()) instant = parseIsoInstant(f.lastUsed);
    if (instant.isValid()) {
        const QTimeZone zone = now.timeZone().isValid() ? now.timeZone() : QTimeZone::systemTimeZone();
        const QDate localDate = instant.toTimeZone(zone).date();
        const qint64 days = localDate.daysTo(now.toTimeZone(zone).date());
        const QString rel = relativeDayLabel(days);
        if (!rel.isEmpty()) return rel;
        return localDate.toString(Qt::ISODate);
    }
    if (f.idleDays >= 0) {
        const QString rel = relativeDayLabel(f.idleDays);
        if (!rel.isEmpty()) return rel;
        return QString::number(f.idleDays) + QStringLiteral(" days ago");
    }
    return QStringLiteral("-");
}

QString displayName(const Finding &f) {
    if (!f.name.isEmpty()) return f.name;
    if (!f.id.isEmpty()) return f.id;
    if (!f.path.isEmpty()) return QFileInfo(f.path).fileName();
    return QStringLiteral("-");
}

QString statusLabel(const Finding &f) {
    if (f.status == QLatin1String("review")) return QStringLiteral("Review");
    if (f.status == QLatin1String("remove")) return QStringLiteral("Remove");
    if (f.status.isEmpty()) return QStringLiteral("-");
    QString s = f.status;
    s[0] = s[0].toUpper();
    return s;
}

bool isProtectedPackagedPath(const QString &path) {
    if (path.isEmpty()) return false;
    static const char *kRoots[] = {
        "/usr", "/bin", "/sbin", "/etc", "/System", "/lib", "/lib64",
        "/boot", "/dev", "/proc", "/sys", "/private", "/Library",
    };
    for (const char *root : kRoots) {
        const QLatin1String r(root);
        if (path == r || path.startsWith(r + QLatin1Char('/'))) return true;
    }
    return false;
}

static bool commandRemovesProtectedPath(const QString &cmd) {
    if (!cmd.contains(QLatin1String("rm ")) && !cmd.contains(QLatin1String("rm\t"))
        && !cmd.startsWith(QLatin1String("rm"))) {
        return false;
    }
    auto has = [&](const char *root) {
        const QString r = QLatin1String(root);
        return cmd.contains(QLatin1Char(' ') + r)
            || cmd.contains(QLatin1Char('\'') + r)
            || cmd.contains(QLatin1Char('"') + r);
    };
    return has("/usr") || has("/bin") || has("/sbin") || has("/etc")
        || has("/System") || has("/lib") || has("/lib64") || has("/boot")
        || has("/dev") || has("/proc") || has("/sys") || has("/private")
        || has("/Library");
}

bool isShadowFinding(const Finding &f) {
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

QString leftoverCleanupCommand(const Finding &f) {
    if (isShadowFinding(f)) {
        if (f.path.isEmpty()) return {};
        if (!f.packagedPath.isEmpty() && f.path == f.packagedPath) return {};
        if (isProtectedPackagedPath(f.path)) return {};
        return QStringLiteral("rm -f ") + shellQuote(f.path);
    }
    if (f.command.isEmpty()) return {};
    const QString cmd = f.command;
    if (commandRemovesProtectedPath(cmd)) return {};
    return cmd;
}

bool isLeftover(const Finding &f) {
    if (f.plugin.startsWith(QLatin1String("path-"))) return true;
    if (f.kind.contains(QLatin1String("orphan-dir"))) return true;
    if (f.kind.contains(QLatin1String("orphan-user-data"))) return true;
    if (f.kind.contains(QLatin1String("overlay")) || isShadowFinding(f)) return true;
    return false;
}

bool isOutdated(const Finding &f) {
    if (!f.currentVersion.isEmpty() || !f.latestVersion.isEmpty()) return true;
    if (f.kind.contains(QLatin1String("outdated")) || f.kind.contains(QLatin1String("upgrade"))) return true;
    if (f.status == QLatin1String("outdated") || f.updatable) return true;
    if (!f.updateCommand.isEmpty()) return true;
    return false;
}

bool hasUsageTiming(const Finding &f) {
    return f.idleDays >= 0 || !f.mtime.isEmpty() || !f.lastUsed.isEmpty();
}

bool isStaleTierStatus(const QString &status) {
    return status == QLatin1String("review") || status == QLatin1String("remove")
        || status == QLatin1String("stale");
}

/// Linux stand-in until a stale WASM plugin ships: path leftovers with idle/mtime
/// (Swift stale = installed apps with review/remove tier; same columns when JSON has timing).
bool isStaleFromLeftoverUsage(const Finding &f) {
    return isLeftover(f) && !isShadowFinding(f) && hasUsageTiming(f);
}

bool isStale(const Finding &f) {
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

void enrichLeftoverUsageTiming(Finding &f) {
    if (!isLeftover(f) || isShadowFinding(f) || hasUsageTiming(f) || f.path.isEmpty()) return;
    const QFileInfo fi(f.path);
    if (!fi.exists()) return;
    const QDateTime mt = fi.lastModified();
    if (!mt.isValid()) return;
    f.mtime = mt.toUTC().toString(Qt::ISODate);
    const qint64 days = localCalendarDaysSince(mt, QDateTime::currentDateTime());
    f.idleDays = days < 0 ? 0 : days;
}

void enrichFindingsUsageTiming(QVector<Finding> &findings) {
    for (Finding &f : findings) enrichLeftoverUsageTiming(f);
}

bool isPackage(const Finding &f) {
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

bool matchPage(const Finding &f, Page page) {
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

int countPageRows(const QVector<Finding> &findings, Page page) {
    int n = 0;
    for (const Finding &f : findings) {
        if (matchPage(f, page)) ++n;
    }
    return n;
}

void appendFindingsFromBlob(QVector<Finding> &out, const QByteArray &line) {
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
        row.command = jsonStr(f, "command");
        row.updateCommand = jsonStr(f, "update_command");
        row.reason = jsonStr(f, "reason");
        row.summary = jsonStr(f, "summary");
        row.rootLabel = jsonStr(f, "rootLabel");
        row.manager = jsonStr(f, "manager");
        row.revision = jsonStr(f, "revision");
        row.currentVersion = jsonStr(f, "current_version");
        row.latestVersion = jsonStr(f, "latest_version");
        row.lastUsed = jsonStr(f, "last_used");
        row.mtime = jsonStr(f, "mtime");
        row.version = jsonStr(f, "version");
        row.packagedPath = jsonStr(f, "shadows");
        if (row.rootLabel.isEmpty() && isShadowFinding(row)) {
            row.rootLabel = overlayRootLabel(row.path);
        }
        row.dialogBody = row.reason.isEmpty() ? dialogBody : row.reason;
        if (row.dialogBody.isEmpty()) row.dialogBody = note;
        row.bytes = jsonIntAny(f, {"bytes", "size_bytes", "size"});
        row.idleDays = jsonIntAny(f, {"idleDays", "idle_days", "idle"});
        row.updatable = parseUpdatable(f, row);
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
        const QJsonValue extra = f.value(QLatin1String("extra_paths"));
        if (extra.isArray()) {
            for (const QJsonValue &p : extra.toArray()) {
                if (p.isString() && !p.toString().isEmpty()) row.extraPaths << p.toString();
            }
            row.extraPaths.removeDuplicates();
        }
        out.push_back(row);
    }
}

bool isGlobalKind(const Finding &f) {
    return f.kind.contains(QLatin1String("global"))
        || f.plugin == QLatin1String("npm") || f.plugin == QLatin1String("pnpm")
        || f.plugin == QLatin1String("bun") || f.plugin == QLatin1String("pipx")
        || f.plugin == QLatin1String("uv");
}

QString distroManager(const Finding &f) {
    QString m = f.manager;
    if (m.isEmpty()) m = f.engine;
    if (m.isEmpty()) m = f.plugin;
    return m.toLower();
}

bool canMarkManual(const Finding &f) {
    if (isGlobalKind(f)) return false;
    if (f.kind != QLatin1String("orphan") && !f.kind.contains(QLatin1String("orphan"))) return false;
    const QString m = distroManager(f);
    return m == QLatin1String("apt") || m == QLatin1String("pacman")
        || m == QLatin1String("dnf") || m == QLatin1String("zypper");
}

QString markManualCommand(const Finding &f) {
    if (!canMarkManual(f)) return {};
    const QString q = shellQuote(displayName(f));
    const QString m = distroManager(f);
    if (m == QLatin1String("apt")) return QStringLiteral("apt-mark manual ") + q;
    if (m == QLatin1String("pacman")) return QStringLiteral("pacman -D --asexplicit ") + q;
    if (m == QLatin1String("dnf")) return QStringLiteral("dnf mark install ") + q;
    if (m == QLatin1String("zypper")) return QStringLiteral("zypper --non-interactive install ") + q;
    return {};
}

bool canMarkCleanup(const Finding &f, Page page) {
    if (page == Page::Outdated) {
        return f.updatable;
    }
    if (f.status == QLatin1String("keep")) return false;
    if (isLeftover(f)) return !leftoverCleanupCommand(f).isEmpty();
    return !f.command.isEmpty() || f.status == QLatin1String("orphaned")
        || f.status == QLatin1String("review") || isShadowFinding(f);
}

QStringList leftoverIgnoreKeys(const Finding &f) {
    QStringList keys;
    if (!f.path.isEmpty()) keys << f.path;
    keys << f.extraPaths;
    if (keys.isEmpty()) keys << f.uid();
    keys.removeDuplicates();
    return keys;
}

bool leftoverIsIgnored(const Finding &f, const QSet<QString> &ignored) {
    if (ignored.isEmpty()) return false;
    for (const QString &k : leftoverIgnoreKeys(f)) {
        if (ignored.contains(pathIdentityKey(k))) return true;
    }
    return false;
}
