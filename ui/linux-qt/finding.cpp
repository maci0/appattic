#include "finding.h"
#include "diskusage.h"

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
#include <QMap>
#include <QRegularExpression>
#include <QSet>
#include <QTimeZone>

#include <atomic>
#include <initializer_list>
#include <limits>
#include <thread>
#include <vector>

static qint64 jsonInt(const QJsonObject &o, const char *key) {
    const QJsonValue v = o.value(QLatin1String(key));
    if (v.isDouble()) return v.toInteger(-1);
    if (v.isString()) {
        bool ok = false;
        const qint64 n = v.toString().toLongLong(&ok);
        return ok ? n : -1;
    }
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

QString expandHomeUserPlaceholder(const QString &text, const QString &home) {
    const QString homePath = QDir::cleanPath(home.isEmpty() ? QDir::homePath() : home);
    if (homePath.size() <= 1 || homePath == QLatin1String("/home/user")) return text;
    QString out = text;
    out.replace(QStringLiteral("/home/user/"), homePath + QLatin1Char('/'));
    const QString exact = QStringLiteral("/home/user");
    if (out.size() >= exact.size() && out.endsWith(exact)) {
        const int before = out.size() - exact.size();
        if (before == 0) return homePath;
        const QChar c = out.at(before - 1);
        if (c == QLatin1Char(' ') || c == QLatin1Char('"') || c == QLatin1Char('\'')) {
            out.chop(exact.size());
            out += homePath;
        }
    }
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
    if (kind.contains(QLatin1String("untrusted"))) return false;
    // Manager alone does not imply an upgrade path. The flatpak plugin also
    // reports unused-runtime rows whose command is "flatpak uninstall -y",
    // which must never be promoted to an update action.
    if (!kind.isEmpty() && !kind.contains(QLatin1String("outdated"))
        && !kind.contains(QLatin1String("upgrade"))) {
        return false;
    }
    return manager == QLatin1String("brew-formula")
        || manager == QLatin1String("brew-cask")
        || manager == QLatin1String("flatpak")
        || manager == QLatin1String("apt")
        || manager == QLatin1String("pacman")
        || manager == QLatin1String("aur")
        || manager == QLatin1String("dnf")
        || manager == QLatin1String("yum")
        || manager == QLatin1String("zypper");
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
    if (kind == QLatin1String("ppa")) return QStringLiteral("PPA");
    if (kind == QLatin1String("orphan") || kind.contains(QLatin1String("orphan"))) {
        return QStringLiteral("Orphan");
    }
    QString s = kind;
    s.replace(QLatin1Char('-'), QLatin1Char(' '));
    if (!s.isEmpty()) s[0] = s[0].toUpper();
    return s.isEmpty() ? QStringLiteral("-") : s;
}

QString pluginScanLabel(const QString &pluginId) {
    QString id = pluginId;
    id.replace(QLatin1Char('_'), QLatin1Char('-'));
    if (id == QLatin1String("leftover-sizes")) {
        return QStringLiteral("Measuring leftover sizes");
    }
    if (id == QLatin1String("path-home-dot")) {
        return QStringLiteral("Scanning leftover data in the home folder");
    }
    if (id == QLatin1String("path-xdg-config")) {
        return QStringLiteral("Scanning leftover config files");
    }
    if (id == QLatin1String("path-xdg-data")) {
        return QStringLiteral("Scanning leftover app data");
    }
    if (id == QLatin1String("path-xdg-cache")) {
        return QStringLiteral("Scanning leftover caches");
    }
    if (id == QLatin1String("path-xdg-state")) {
        return QStringLiteral("Scanning leftover state files");
    }
    if (id == QLatin1String("path-xdg-lib")) {
        return QStringLiteral("Scanning leftover libraries");
    }
    if (id == QLatin1String("path-var-app")) {
        return QStringLiteral("Scanning leftover Flatpak data");
    }
    if (id == QLatin1String("path-shadow")) {
        return QStringLiteral("Scanning PATH overlays");
    }
    if (id == QLatin1String("path-user-bin")) {
        return QStringLiteral("Scanning user binaries");
    }
    if (id.startsWith(QLatin1String("path-"))) {
        return QStringLiteral("Scanning leftover data");
    }
    if (id == QLatin1String("pacman")) return QStringLiteral("Checking pacman packages");
    if (id == QLatin1String("aur")) return QStringLiteral("Checking AUR packages");
    if (id == QLatin1String("apt")) return QStringLiteral("Checking apt packages");
    if (id == QLatin1String("dnf")) return QStringLiteral("Checking dnf packages");
    if (id == QLatin1String("zypper")) return QStringLiteral("Checking zypper packages");
    if (id == QLatin1String("flatpak")) return QStringLiteral("Checking Flatpak apps");
    if (id == QLatin1String("snapd")) return QStringLiteral("Checking Snap packages");
    if (id == QLatin1String("npm")) return QStringLiteral("Checking npm global packages");
    if (id == QLatin1String("pnpm")) return QStringLiteral("Checking pnpm global packages");
    if (id == QLatin1String("bun")) return QStringLiteral("Checking bun global packages");
    if (id == QLatin1String("pipx")) return QStringLiteral("Checking pipx tools");
    if (id == QLatin1String("pip")) return QStringLiteral("Checking pip packages");
    if (id == QLatin1String("uv")) return QStringLiteral("Checking uv tools");
    if (id == QLatin1String("brew")) return QStringLiteral("Checking Homebrew packages");
    if (id == QLatin1String("gem")) return QStringLiteral("Checking Ruby gems");
    if (id == QLatin1String("composer")) return QStringLiteral("Checking Composer packages");
    if (id == QLatin1String("container-runtime")) return QStringLiteral("Checking containers");
    if (id == QLatin1String("deno")) return QStringLiteral("Checking Deno global installs");
    if (id.isEmpty()) return QStringLiteral("Scanning");
    id.replace(QLatin1Char('-'), QLatin1Char(' '));
    return QStringLiteral("Checking ") + id;
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

static bool leftoverStatusBlocksCleanup(const QString &status) {
    return status == QLatin1String("keep")
        || status == QLatin1String("owned")
        || status == QLatin1String("system");
}

static bool isPpaSourcesPath(const QString &path) {
    const QString clean = QDir::cleanPath(path);
    if (clean.contains(QLatin1String(".."))) return false;
    return clean.startsWith(QLatin1String("/etc/apt/sources.list.d/"));
}

QString leftoverCleanupCommand(const Finding &f) {
    if (leftoverStatusBlocksCleanup(f.status)) return {};
    if (isShadowFinding(f)) {
        if (f.path.isEmpty()) return {};
        if (!f.packagedPath.isEmpty() && f.path == f.packagedPath) return {};
        if (isProtectedPackagedPath(f.path)) return {};
        return QStringLiteral("rm -f ") + shellQuote(f.path);
    }
    if (isLeftover(f)) {
        QStringList paths;
        auto add = [&](const QString &p) {
            if (p.isEmpty() || paths.contains(p)) return;
            if (isProtectedPackagedPath(p) && !isPpaSourcesPath(p)) return;
            paths << p;
        };
        add(f.path);
        for (const QString &p : f.extraPaths) add(p);
        if (!paths.isEmpty()) {
            const bool fileOnly = f.kind.contains(QLatin1String("symlink"))
                || f.plugin == QLatin1String("path-user-bin")
                || f.kind.contains(QLatin1String("ppa"));
            QString cmd = fileOnly ? QStringLiteral("rm -f") : QStringLiteral("rm -rf");
            for (const QString &p : paths) {
                cmd += QLatin1Char(' ');
                cmd += shellQuote(p);
            }
            return cmd;
        }
    }
    if (f.command.isEmpty()) return {};
    const QString cmd = f.command;
    if (commandRemovesProtectedPath(cmd)) return {};
    return cmd;
}

static bool isSafePackageName(const QString &n) {
    if (n.isEmpty()) return false;
    for (const QChar c : n) {
        if (c.isLetterOrNumber() || c == QLatin1Char('-') || c == QLatin1Char('_')
            || c == QLatin1Char('.') || c == QLatin1Char('+') || c == QLatin1Char('@')
            || c == QLatin1Char('/')) {
            continue;
        }
        return false;
    }
    return true;
}

QString packageChildCommand(const Finding &f, const QString &child) {
    if (!isSafePackageName(child) || f.command.trimmed().isEmpty()) return {};
    const QString cmd = f.command.trimmed();
    const int sp = cmd.lastIndexOf(QLatin1Char(' '));
    if (sp <= 0) return {};
    return cmd.left(sp + 1) + shellQuote(child);
}

bool commandNeedsRoot(const QString &cmd) {
    QString t = cmd.trimmed();
    if (t.startsWith(QLatin1String("rootcmd "))) return false;
    QString first = t.section(QLatin1Char(' '), 0, 0);
    if (first.contains(QLatin1Char('/'))) first = first.section(QLatin1Char('/'), -1);
    return first == QLatin1String("apt-get")
        || first == QLatin1String("apt-mark")
        || first == QLatin1String("apt")
        || first == QLatin1String("pacman")
        || first == QLatin1String("paru")
        || first == QLatin1String("yay")
        || first == QLatin1String("pikaur")
        || first == QLatin1String("dnf")
        || first == QLatin1String("dnf5")
        || first == QLatin1String("yum")
        || first == QLatin1String("zypper")
        || first == QLatin1String("snap")
        || t.contains(QLatin1String(" '/etc/apt/sources.list.d/"))
        || t.contains(QLatin1String(" /etc/apt/sources.list.d/"));
}

QString withRootCmd(const QString &cmd) {
    if (cmd.isEmpty() || !commandNeedsRoot(cmd)) return cmd;
    return QStringLiteral("rootcmd ") + cmd;
}

QString scriptRootHelper() {
    return QStringLiteral(
        "rootcmd() {\n"
        "  if [ \"$(id -u)\" -eq 0 ]; then\n"
        "    \"$@\"\n"
        "  elif command -v pkexec >/dev/null 2>&1; then\n"
        "    pkexec \"$@\"\n"
        "  else\n"
        "    sudo \"$@\"\n"
        "  fi\n"
        "}");
}

static void addLeftoverAliasTokens(QSet<QString> *out, QString token);

QString leftoverGroupKey(const QString &name) {
    QSet<QString> tok;
    addLeftoverAliasTokens(&tok, name);
    if (tok.isEmpty()) return {};
    QStringList keys = tok.values();
    keys.sort();
    return keys.first();
}

void groupLinuxLeftovers(QVector<Finding> &findings) {
    QMap<QString, QVector<int>> buckets;
    for (int i = 0; i < findings.size(); ++i) {
        const Finding &f = findings[i];
        if (!isLeftover(f) || isShadowFinding(f)) continue;
        if (f.status != QLatin1String("orphaned")) continue;
        if (f.kind.contains(QLatin1String("ppa"))) continue;
        if (f.plugin == QLatin1String("path-user-bin")) continue;
        const QString key = leftoverGroupKey(f.name);
        if (key.size() < 2) continue;
        buckets[key].append(i);
    }
    QSet<int> drop;
    for (auto it = buckets.cbegin(); it != buckets.cend(); ++it) {
        const QVector<int> &idx = it.value();
        if (idx.size() < 2) continue;
        int primary = idx[0];
        for (int i : idx) {
            if (findings[i].bytes > findings[primary].bytes) primary = i;
        }
        for (int i : idx) {
            if (i == primary) continue;
            if (!findings[i].path.isEmpty()) findings[primary].extraPaths << findings[i].path;
            findings[primary].extraPaths << findings[i].extraPaths;
            if (findings[i].bytes > 0) {
                if (findings[primary].bytes < 0) findings[primary].bytes = 0;
                findings[primary].bytes += findings[i].bytes;
            }
            drop.insert(i);
        }
        findings[primary].extraPaths.removeDuplicates();
        findings[primary].extraPaths.removeAll(findings[primary].path);
    }
    if (drop.isEmpty()) return;
    QVector<Finding> kept;
    kept.reserve(findings.size() - drop.size());
    for (int i = 0; i < findings.size(); ++i) {
        if (!drop.contains(i)) kept << findings[i];
    }
    findings.swap(kept);
}

bool isLeftover(const Finding &f) {
    if (f.plugin.startsWith(QLatin1String("path-"))) return true;
    if (f.kind.contains(QLatin1String("orphan-dir"))) return true;
    if (f.kind.contains(QLatin1String("orphan-user-data"))) return true;
    if (f.kind == QLatin1String("ppa") || f.kind.contains(QLatin1String("ppa"))) return true;
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

/// Leftover dirs are not unused apps. Stale stays empty on Linux until a stale plugin ships.
bool isStaleFromLeftoverUsage(const Finding &f) {
    (void)f;
    return false;
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

void enrichLeftoverSizes(
    QVector<Finding> &findings,
    bool (*cancelled)(void *user),
    void *user
) {
    std::vector<Finding *> jobs;
    jobs.reserve(size_t(findings.size()));
    for (Finding &f : findings) {
        if (!isLeftover(f)) continue;
        if (f.status == QLatin1String("keep") || f.status == QLatin1String("owned")
            || f.status == QLatin1String("system")) {
            continue;
        }
        jobs.push_back(&f);
    }
    if (jobs.empty()) return;
    unsigned nw = std::thread::hardware_concurrency();
    if (nw == 0) nw = 2;
    if (nw > 4) nw = 4;
    if (nw > unsigned(jobs.size())) nw = unsigned(jobs.size());
    DiskScanOptions opts;
    opts.oneFileSystem = true;
    opts.cancelled = cancelled;
    opts.user = user;
    std::atomic<size_t> next{0};
    auto measureOne = [&](Finding &f) {
        qint64 total = 0;
        bool any = false;
        auto add = [&](const QString &p) {
            if (p.isEmpty()) return;
            if (isProtectedPackagedPath(p)
                && !p.startsWith(QLatin1String("/etc/apt/sources.list.d/"))) {
                return;
            }
            const qint64 n = measurePathBytes(p, opts);
            if (n < 0) return;
            if (total > std::numeric_limits<qint64>::max() - n) {
                total = std::numeric_limits<qint64>::max();
            } else {
                total += n;
            }
            any = true;
        };
        add(f.path);
        for (const QString &p : f.extraPaths) add(p);
        if (any) f.bytes = total;
    };
    std::vector<std::thread> threads;
    threads.reserve(nw);
    for (unsigned t = 0; t < nw; t++) {
        threads.emplace_back([&] {
            for (;;) {
                if (cancelled && cancelled(user)) break;
                const size_t k = next.fetch_add(1);
                if (k >= jobs.size()) break;
                if (cancelled && cancelled(user)) break;
                measureOne(*jobs[k]);
            }
        });
    }
    for (std::thread &th : threads) th.join();
}

static void addLeftoverAliasTokens(QSet<QString> *out, QString token) {
    if (token.startsWith(QLatin1Char('.'))) token = token.mid(1);
    token.replace(QLatin1Char('_'), QLatin1Char('-'));
    token = token.toLower();
    if (token.isEmpty()) return;
    out->insert(token);
    if (token == QLatin1String("firefox") || token == QLatin1String("firefoxwebbrowser")) {
        out->insert(QStringLiteral("mozilla"));
        out->insert(QStringLiteral("firefox"));
    } else if (token == QLatin1String("mozilla")) {
        out->insert(QStringLiteral("firefox"));
    } else if (token == QLatin1String("visualstudiocode") || token == QLatin1String("vscode")
               || token == QLatin1String("code")) {
        out->insert(QStringLiteral("code"));
        out->insert(QStringLiteral("vscode"));
        out->insert(QStringLiteral("visualstudiocode"));
    } else if (token == QLatin1String("chromium") || token == QLatin1String("googlechrome")) {
        out->insert(QStringLiteral("chrome"));
        out->insert(QStringLiteral("chromium"));
    } else if (token == QLatin1String("thunderbird")) {
        out->insert(QStringLiteral("thunderbird"));
    }
}

bool leftoverNameMatchesDesktop(const QString &name, const QSet<QString> &stems) {
    QSet<QString> leftoverTok;
    addLeftoverAliasTokens(&leftoverTok, name);
    if (leftoverTok.isEmpty()) return false;
    for (const QString &stem : stems) {
        QSet<QString> stemTok;
        addLeftoverAliasTokens(&stemTok, stem);
        if (!leftoverTok.intersects(stemTok)) continue;
        return true;
    }
    return false;
}

static QSet<QString> installedDesktopStems() {
    QSet<QString> stems;
    const QStringList dirs = {
        QStringLiteral("/usr/share/applications"),
        QStringLiteral("/usr/local/share/applications"),
        QDir::home().filePath(QStringLiteral(".local/share/applications")),
        QStringLiteral("/var/lib/flatpak/exports/share/applications"),
        QDir::home().filePath(QStringLiteral(".local/share/flatpak/exports/share/applications")),
        QStringLiteral("/var/lib/snapd/desktop/applications"),
    };
    for (const QString &dir : dirs) {
        const QDir d(dir);
        if (!d.exists()) continue;
        const QStringList files = d.entryList({QStringLiteral("*.desktop")}, QDir::Files);
        for (QString file : files) {
            if (file.endsWith(QLatin1String(".desktop"))) file.chop(8);
            const QString low = file.toLower();
            if (low.isEmpty()) continue;
            stems.insert(low);
            const int dot = low.lastIndexOf(QLatin1Char('.'));
            if (dot > 0) stems.insert(low.mid(dot + 1));
        }
    }
    return stems;
}

void markOwnedPathLeftovers(QVector<Finding> &findings) {
    const QSet<QString> stems = installedDesktopStems();
    if (stems.isEmpty()) return;
    for (Finding &f : findings) {
        if (!isLeftover(f) || isShadowFinding(f)) continue;
        if (f.status == QLatin1String("keep")) continue;
        if (leftoverNameMatchesDesktop(f.name, stems)) f.status = QStringLiteral("keep");
    }
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
        if (!isLeftover(f)) return false;
        if (f.status == QLatin1String("keep") || f.status == QLatin1String("owned")
            || f.status == QLatin1String("system")) {
            return false;
        }
        return true;
    case Page::Stale:
        return isStale(f);
    case Page::Outdated:
        return isOutdated(f);
    case Page::Packages:
        return isPackage(f);
    case Page::DiskUsage:
        return false;
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
        row.path = expandHomeUserPlaceholder(jsonStr(f, "path"));
        row.status = jsonStr(f, "status");
        row.command = expandHomeUserPlaceholder(jsonStr(f, "command"));
        row.updateCommand = expandHomeUserPlaceholder(jsonStr(f, "update_command"));
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
        row.packagedPath = expandHomeUserPlaceholder(jsonStr(f, "shadows"));
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
                if (p.isString() && !p.toString().isEmpty()) {
                    row.extraPaths << expandHomeUserPlaceholder(p.toString());
                }
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
        || f.plugin == QLatin1String("uv") || f.plugin == QLatin1String("pip")
        || f.plugin == QLatin1String("deno");
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
    if (m == QLatin1String("dpkg") || m == QLatin1String("yum") || m == QLatin1String("aur")) {
        return false;
    }
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
