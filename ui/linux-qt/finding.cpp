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
#include <QLocale>
#include <QMap>
#include <QRegularExpression>
#include <QSet>
#include <QTimeZone>
#include <QtGui/QTextDocument>

#include <atomic>
#include <initializer_list>
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

/// Case form for comparing typed text against text read off the disk.
///
/// `toCaseFolded()` alone is not enough: an exFAT, NTFS, or SMB share hands
/// back decomposed filenames, a keyboard and a paste give the precomposed
/// spelling, and "Café" and "Cafe" + U+0301 are different QStrings, so a
/// search for "café" finds nothing. NFC is the form `pathIdentityKey` already
/// uses for identity, so the search uses the same one. Diacritics are not
/// stripped: "cafe" still does not match "Café".
///
/// Case folding, not `toLower()`: the two differ on letters whose two case
/// forms are distinct letters rather than the same letter, and a name spelled
/// with one of them then never matches a search for the other. The final
/// sigma is the case Qt gets different today: `toLower()` leaves ς alone,
/// `toCaseFolded()` folds it to σ, so a name spelled "ὀδυσσεύς" is found by a
/// search for "ὀδυσσεύσ".
QString searchFold(const QString &s) {
    return s.toCaseFolded().normalized(QString::NormalizationForm_C);
}

QString plainTooltip(const QString &s) {
    return Qt::convertFromPlainText(s);
}

QString redactHomePaths(const QString &text, const QString &home) {
    const QString homePath = pathIdentityKey(QDir::cleanPath(home.isEmpty() ? QDir::homePath() : home));
    if (homePath.size() <= 1) return text;
    // The home path is matched in both canonical forms rather than the message
    // being normalized: `$HOME` arrives composed while a path off a decomposed
    // mount spells the same directory with combining marks, and the two never
    // match as literal text, so the account name rides out in the status bar
    // instead of being replaced. Normalizing the haystack instead would
    // re-spell every path in it, and on a decomposed mount NFC and NFD are
    // different files, so the user would be invited to copy back a path that
    // does not exist.
    QString pattern = QRegularExpression::escape(homePath);
    const QString decomposed = homePath.normalized(QString::NormalizationForm_D);
    if (decomposed != homePath) {
        pattern = QStringLiteral("(?:") + pattern + QLatin1Char('|')
            + QRegularExpression::escape(decomposed) + QLatin1Char(')');
    }
    // The lookahead matches everything but a character that could continue a
    // path, so a home path in a parenthetical or bracketed message is
    // redacted like one followed by a separator. Same set as Swift
    // `isHomeBoundary`.
    const QRegularExpression re(pattern + QStringLiteral("(?=/|$|[^A-Za-z0-9._~+=-])"));
    if (!text.contains(re)) return text;
    QString out = text;
    out.replace(re, QStringLiteral("~"));
    return out;
}

QString expandHomeUserPlaceholder(const QString &text, const QString &home) {
    const QString homePath = QDir::cleanPath(home.isEmpty() ? QDir::homePath() : home);
    QString out = text;
    // The XDG roots first, and before the home fallback: the core scanned
    // `$XDG_CONFIG_HOME` when it was set, so a finding reported against
    // `~/.config` would name a directory the run never looked at. An empty or
    // relative value is ignored, as the XDG specification says, and the test is
    // "does it start with a slash" so a value of `/` is a root like any other,
    // the way `Sources/AppAtticScan/Paths.swift` and `core/host/hostexec.c`
    // read it.
    static const struct { const char *rel; const char *env; } kXdgRoots[] = {
        {"/.local/share", "XDG_DATA_HOME"},
        {"/.local/state", "XDG_STATE_HOME"},
        {"/.config", "XDG_CONFIG_HOME"},
        {"/.cache", "XDG_CACHE_HOME"},
    };
    for (const auto &root : kXdgRoots) {
        QString value = QString::fromUtf8(qgetenv(root.env)).trimmed();
        if (value.isEmpty() || !value.startsWith(QLatin1Char('/'))) continue;
        // The placeholder is replaced by the root on its own, and the separator
        // that followed it in the text is still after the match, so a root that
        // ends in one would double it: with `XDG_DATA_HOME=/`,
        // `/home/user/.local/share/applications/foo.desktop` has to name
        // `/applications/foo.desktop` rather than `//applications/foo.desktop`.
        while (value.endsWith(QLatin1Char('/'))) {
            value.chop(1);
        }
        out.replace(QStringLiteral("/home/user") + QLatin1String(root.rel), value);
    }
    if (homePath.size() <= 1 || homePath == QLatin1String("/home/user")) return out;
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

/// One decimal place in the user's own digits.
///
/// `QString::number` and `QString::toString` stay in the C locale, so both the
/// decimal point and the digits were ASCII: a German window read "1.5 GB"
/// (thousands punctuation where a decimal comma belongs) and an Arabic one read
/// "1.5 GB" in Latin digits, where every other number in the same row came out
/// in Arabic-Indic digits. `QLocale::toString` writes the locale's own digit
/// set, decimal separator and negative sign, so the fraction matches the
/// `localeCount` whole part beside it.
///
/// The thousands grouping it adds is dropped: a size is at most the leading
/// mantissa (humanSize stops at EB), and "1.024,0 KB" in a column labelled
/// "size" reads as a different number from the one the table sorts on. Removing
/// the group separator cannot touch a digit run, since the mantissa is always
/// below 1000.
static QString fixed1(double value) {
    const QLocale loc;
    QString s = loc.toString(value, 'f', 1);
    const QString group = loc.groupSeparator();
    if (!group.isEmpty()) s.remove(group);
    return s;
}

/// A date for a display column, in the user's own date order. The C locale
/// carries no date format of its own (Qt synthesises "7 03 2026"), so it keeps
/// ISO, which is the unambiguous form tools in that locale expect.
QString localeDateLabel(const QDate &date) {
    const QLocale loc;
    if (loc.name() == QLatin1String("C")) return date.toString(Qt::ISODate);
    return loc.toString(date, QLocale::ShortFormat);
}

/// The same rule for a timestamp that carries a time of day.
QString localeDateTimeLabel(const QDateTime &dt) {
    const QLocale loc;
    if (loc.name() == QLatin1String("C")) return dt.toString(Qt::ISODate);
    return loc.toString(dt, QLocale::ShortFormat);
}

/// A whole number in the user's own grouping. `QString::number` stays in the C
/// locale, so a count of 1234567 reads as "1234567" in German and French
/// instead of "1.234.567", and the same count renders two different ways
/// depending on which column it came from. The C locale has no grouping rules,
/// so it keeps the plain digits that tools in that locale expect.
QString localeCount(qlonglong n) {
    const QLocale loc;
    if (loc.name() == QLatin1String("C")) return QString::number(n);
    return loc.toString(n);
}

QString humanSize(qint64 bytes) {
    if (bytes < 0) return QStringLiteral("unknown");
    double n = double(bytes);
    // The list has to reach the unit a qint64 saturates at (8 EiB), so a size
    // past PB prints as "8.0 EB" and not "8192.0 PB". Same list as the Swift
    // `humanSize`, so both windows label the same value the same way.
    static const char *units[] = {"B", "KB", "MB", "GB", "TB", "PB", "EB"};
    const int last = int(sizeof(units) / sizeof(units[0])) - 1;
    int unit = 0;
    while (unit < last) {
        if (qAbs(n) < 1024.0) {
            if (qRound(qAbs(n) * 10.0) / 10.0 >= 1024.0) {
                n /= 1024.0;
                unit += 1;
                continue;
            }
            if (unit == 0) return localeCount(bytes) + QStringLiteral(" B");
            return fixed1(n) + QLatin1Char(' ') + QLatin1String(units[unit]);
        }
        n /= 1024.0;
        unit += 1;
    }
    return fixed1(n) + QLatin1Char(' ') + QLatin1String(units[unit]);
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
/// Date-only `yyyy-MM-dd` is that calendar day at UTC midnight, matching
/// parseISODate too: a bare date names an instant, not a wall-clock day, and
/// UTC midnight is unambiguous where local midnight is not (nonexistent on a
/// spring-forward, doubled on a fall-back). Both windows read the same scan
/// JSON, so a stored bare date has to land on the same instant in each.
QDateTime parseIsoInstant(const QString &value) {
    QString s = value.trimmed();
    if (s.isEmpty()) return {};
    if (s.endsWith(QLatin1Char('z'))) s[s.size() - 1] = QLatin1Char('Z');

    if (s.size() == 10 && s[4] == QLatin1Char('-') && s[7] == QLatin1Char('-')) {
        const QDate d = QDate::fromString(s, Qt::ISODate);
        if (d.isValid()) return QDateTime(d, QTime(0, 0), QTimeZone::utc());
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

/// Empty for a negative count, so a timestamp in the future (a restored
/// archive, a file written while the clock was ahead) renders as its local
/// date instead of claiming the file changed today.
static QString relativeDayLabel(qint64 days) {
    if (days == 0) return QStringLiteral("Today");
    if (days == 1) return QStringLiteral("Yesterday");
    if (days < 2 || days >= 45) return {};
    return localeCount(days) + QStringLiteral(" days ago");
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
        return localeDateLabel(localDate);
    }
    if (f.idleDays >= 0) {
        const QString rel = relativeDayLabel(f.idleDays);
        if (!rel.isEmpty()) return rel;
        return localeCount(f.idleDays) + QStringLiteral(" days ago");
    }
    // "unknown" for a value that exists but could not be read, "-" for nothing
    // to show: the same words the size and version columns use.
    return QStringLiteral("unknown");
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

/// A `..` path component. A name a scan read off the filesystem cannot be one,
/// so a path carrying it was spelled by something else.
static bool hasParentSegment(const QString &path) {
    return path.split(QLatin1Char('/')).contains(QLatin1String(".."));
}

/// The path with empty and `.` components dropped, for a prefix test. The
/// removal quotes the path as written, so `rm` resolves `//usr` and `/usr/.`
/// to the packaged root a raw prefix test would miss. Matches Swift
/// `normalizedForPrefixTest`.
static QString normalizedForPrefixTest(const QString &path) {
    QStringList parts;
    const QStringList raw = path.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    for (const QString &p : raw) {
        if (p != QLatin1String(".")) parts << p;
    }
    return QLatin1Char('/') + parts.join(QLatin1Char('/'));
}

// The packaged roots a removal may never touch, shared by the path test and
// the command test so a root added to one covers the other.
static const char *const kPackagedRoots[] = {
    "/usr", "/bin", "/sbin", "/etc", "/System", "/lib", "/lib64",
    "/boot", "/dev", "/proc", "/sys", "/private", "/Library",
};

bool isProtectedPackagedPath(const QString &path) {
    if (path.isEmpty()) return false;
    // The removal quotes the path as written, so a `..` segment walks out of
    // whatever the prefix test just approved: `/home/u/gone/../../../etc` is
    // not under a packaged root by spelling and deletes `/etc` once `rm`
    // resolves it.
    if (hasParentSegment(path)) return true;
    const QString normalized = normalizedForPrefixTest(path);
    for (const char *root : kPackagedRoots) {
        const QLatin1String r(root);
        if (normalized == r || normalized.startsWith(r + QLatin1Char('/'))) return true;
    }
    return false;
}

static bool commandRemovesProtectedPath(const QString &cmd) {
    if (!cmd.contains(QLatin1String("rm ")) && !cmd.contains(QLatin1String("rm\t"))
        && !cmd.startsWith(QLatin1String("rm"))) {
        return false;
    }
    // A slash counts as a delimiter because the command is judged on its raw
    // spelling: `rm -rf //usr/bin` carries the packaged root the way
    // `rm -rf /usr/bin` does, and matching only the quoted and spaced forms
    // let the doubled slash through. The set is wider than the paths it can
    // match, which is the safe direction for a deny.
    for (const char *root : kPackagedRoots) {
        const QString r = QLatin1String(root);
        if (cmd.contains(QLatin1Char(' ') + r)
            || cmd.contains(QLatin1Char('\t') + r)
            || cmd.contains(QLatin1Char('\'') + r)
            || cmd.contains(QLatin1Char('"') + r)
            || cmd.contains(QLatin1Char('/') + r)) {
            return true;
        }
    }
    return false;
}

/// A plugin `command` reaches the generated script verbatim, so it may only
/// hold characters that mean nothing to `/bin/sh`. A `;`, `|`, `&`, `$`,
/// backtick, quote, redirect, or newline means the plugin spliced a package
/// name or leftover path into the command without quoting it, and the shell
/// would run whatever follows. Names and paths are attacker controlled (an
/// npm package name, a tap's cask, a file in `~/.local/bin`), and distro
/// lines go through `rootcmd`, so the payload would run as root. Refuse the
/// command instead. Same character set as Zig `jsonbuf.shQuote` and Swift
/// `isSafeShellByte`, plus the space and the single quote a quoted value needs.
/// One single-quoted value, as `shellQuote` writes it, with nothing after the
/// closing quote.
bool isQuotedValue(const QString &s) {
    if (s.size() < 2 || !s.startsWith(QLatin1Char('\'')) || !s.endsWith(QLatin1Char('\'')))
        return false;
    const int last = s.size() - 1;
    int i = 1;
    while (i < last) {
        if (s.at(i) != QLatin1Char('\'')) {
            ++i;
            continue;
        }
        // A `'\''` run is the only way a quote appears inside the value. Any
        // other quote before the last character is not the closing one, so the
        // rest of the guard would be payload, not data.
        if (i + 3 <= last && s.mid(i, 4) == QLatin1String("'\\''")) {
            i += 4;
            continue;
        }
        return false;
    }
    return true;
}

bool commandIsShellSafe(const QString &cmd) {
    if (cmd.isEmpty()) return false;
    // A guarded removal is app-written structure around a plugin command. Two
    // shapes reach here: `if <query> >/dev/null 2>&1; then <action>; fi` and
    // `if <list> | grep -qF -- '<row>'; then <action>; fi`. Both wrappers are
    // what make a second run a no-op instead of a `set -e` abort. The query and
    // the action are judged by the same byte rule as any other command, or the
    // guard would refuse every removal.
    if (const std::optional<GuardedRemove> guarded = parseGuardedRemove(cmd)) {
        static const QString kRedirect = QStringLiteral(" >/dev/null 2>&1");
        static const QString kRowFilter = QStringLiteral(" | grep -qF -- ");
        QString query = guarded->present;
        if (query.endsWith(kRedirect)) query.chop(kRedirect.size());
        // A row guard filters a listing in the guard, so the row is literal
        // data the app quoted: everything after `| grep -qF --` is one quoted
        // value, and the command being checked is what precedes it.
        const int filter = query.indexOf(kRowFilter);
        if (filter >= 0) {
            const QString row = query.mid(filter + kRowFilter.size());
            query.chop(query.size() - filter);
            if (!isQuotedValue(row)) return false;
        }
        return !query.isEmpty() && commandIsShellSafe(query) && commandIsShellSafe(guarded->action);
    }
    bool in_quote = false;
    for (int i = 0; i < cmd.size(); ++i) {
        const QChar c = cmd.at(i);
        if (in_quote) {
            // Everything between single quotes is literal data, including a
            // newline, so only the closing quote matters.
            if (c == QLatin1Char('\'')) in_quote = false;
            continue;
        }
        if (c == QLatin1Char('\'')) {
            in_quote = true;
            continue;
        }
        if (c == QLatin1Char('\\') && i + 1 < cmd.size()
            && cmd.at(i + 1) == QLatin1Char('\'')) {
            ++i;  // the `'\''` spelling shellQuote uses for an embedded quote
            continue;
        }
        if (c.unicode() >= 0x80) continue;
        const char b = char(c.unicode());
        if ((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')) continue;
        switch (b) {
            case '_': case '@': case '%': case '+': case '=':
            case ':': case ',': case '.': case '/': case '-': case ' ':
                continue;
            default:
                return false;
        }
    }
    return !in_quote;
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

/// The statuses that must never be cleaned, ticked, or re-measured.
///
/// One predicate for the whole set, because the set was open-coded at every
/// call site and the sites did not agree: `leftoverCleanupCommand`,
/// `enrichLeftoverSizes`, `matchPage`, `smokeVerifyTables`, and the helper
/// tests each named the same three strings, while `canMarkCleanup` named only
/// "keep". A leftover carrying "owned" or "system" was therefore still stopped
/// by `leftoverCleanupCommand` returning empty, which made the missing guard
/// invisible for exactly the rows it was meant to protect; a row that is not a
/// leftover has no such fallback and fell through on its command alone. The
/// question is "may this row be cleaned", not "did a command come out".
///
/// `markOwnedPathLeftovers` is the one site that does not ask this: it *writes*
/// "keep" and so has to keep offering every other row to the desktop list.
bool leftoverStatusBlocksCleanup(const QString &status) {
    return status == QLatin1String("keep")
        || status == QLatin1String("owned")
        || status == QLatin1String("system");
}

/// A path a generated `rm` may name. Every leftover root the core walks is
/// absolute, and a finding's path is read off the filesystem, so a relative
/// spelling or a leading `-` did not come from a walk. `shellQuote` leaves
/// either one unquoted, so `rm` resolves it against the script's working
/// directory, or reads `--no-preserve-root` as the option it is. Matches Swift
/// `isRemovableLeftoverPath`.
static bool isRemovableLeftoverPath(const QString &path) {
    return !path.isEmpty() && path.startsWith(QLatin1Char('/'))
        && !path.startsWith(QLatin1Char('-'));
}

static bool isPpaSourcesPath(const QString &path) {
    // Tested on the spelling as written, not on the cleaned path: cleanPath
    // resolves `..`, so the check below could never see one and
    // `/etc/apt/sources.list.d/../sources.list.d/x` was re-permitted past the
    // packaged-root deny.
    if (hasParentSegment(path)) return false;
    return QDir::cleanPath(path).startsWith(QLatin1String("/etc/apt/sources.list.d/"));
}

QString leftoverCleanupCommand(const Finding &f) {
    if (leftoverStatusBlocksCleanup(f.status)) return {};
    if (isShadowFinding(f)) {
        if (f.path.isEmpty()) return {};
        if (!f.packagedPath.isEmpty() && f.path == f.packagedPath) return {};
        if (isProtectedPackagedPath(f.path)) return {};
        if (!isRemovableLeftoverPath(f.path)) return {};
        return QStringLiteral("rm -f ") + shellQuote(f.path);
    }
    if (isLeftover(f)) {
        QStringList paths;
        auto add = [&](const QString &p) {
            // Compared in the canonical form, not by raw text: NFC and NFD
            // spellings of one directory are the same directory, and a literal
            // compare lets both through and writes two `rm -rf` lines for it.
            if (!isRemovableLeftoverPath(p)) return;
            const QString key = pathIdentityKey(p);
            for (const QString &seen : paths) {
                if (pathIdentityKey(seen) == key) return;
            }
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
    // A leading `-` reaches the manager as an option, not as a name. The name
    // comes from the plugin's parse of a manager listing, so refuse it rather
    // than quote it into a different command.
    if (n.startsWith(QLatin1Char('-'))) return false;
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
    // The child replaces the last word of the command. On a guarded removal
    // that word is `fi`, and the splice would leave an unparseable line.
    if (parseGuardedRemove(f.command)) return {};
    const QString cmd = f.command.trimmed();
    const int sp = cmd.lastIndexOf(QLatin1Char(' '));
    if (sp <= 0) return {};
    return cmd.left(sp + 1) + shellQuote(child);
}

std::optional<GuardedRemove> parseGuardedRemove(const QString &cmd) {
    const QString t = cmd.trimmed();
    if (!t.startsWith(QLatin1String("if "))) return std::nullopt;
    const int then = t.indexOf(QLatin1String("; then "));
    const int fi = t.lastIndexOf(QLatin1String("; fi"));
    if (then < 0 || fi <= then + 7) return std::nullopt;
    // Nothing may follow the guard. `if q; then id; fi; reboot` would parse to
    // a clean query and action while the tail runs unguarded, and the callers
    // judge only the two halves, so a line with a tail is not a guard at all
    // and the whole-line byte rule has to see it.
    if (!t.mid(fi + 4).trimmed().isEmpty()) return std::nullopt;
    return GuardedRemove{t.mid(3, then - 3), t.mid(then + 7, fi - then - 7).trimmed()};
}

bool commandNeedsRoot(const QString &cmd) {
    QString t = cmd.trimmed();
    if (t.startsWith(QLatin1String("rootcmd "))) return false;
    // A `#` line is a comment. It mentions a path the way a command does, and
    // it runs nothing, so it never escalates.
    if (t.startsWith(QLatin1Char('#'))) return false;
    // A guarded removal is `if <query>; then <action>; fi`. Judge the action,
    // or the leading `if` hides an action that needs root.
    if (const std::optional<GuardedRemove> guarded = parseGuardedRemove(t)) t = guarded->action;
    // Split on any whitespace run, as the Swift twin `commandNeedsRoot` does:
    // a tab-separated `apt\tinstall` is one argument, not two, and would
    // otherwise read as the base name `apt\tinstall` and match no manager.
    QString first = t.simplified().section(QLatin1Char(' '), 0, 0);
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
        || t.contains(QLatin1String(" \"/etc/apt/sources.list.d/"))
        || t.contains(QLatin1String(" /etc/apt/sources.list.d/"));
}

/// Escalate one generated line. A guarded removal keeps the guard outside the
/// wrapper: `rootcmd if q; then rm; fi` is a `/bin/sh` syntax error (`then`
/// outside an `if`), and a syntax error takes the whole script down before its
/// first line runs. The presence check is a read and stays unprivileged; only
/// the action escalates.
QString withRootCmd(const QString &cmd) {
    if (cmd.isEmpty() || !commandNeedsRoot(cmd)) return cmd;
    // Escalating the whole line hands `rootcmd` the words `if` and `<query>` as
    // arguments and leaves a bare `then` behind, so the line stops parsing and
    // `set -e` ends the script there. Escalate the action inside the guard.
    if (const std::optional<GuardedRemove> guarded = parseGuardedRemove(cmd)) {
        return QStringLiteral("if ") + guarded->present
            + QStringLiteral("; then rootcmd ") + guarded->action + QStringLiteral("; fi");
    }
    return QStringLiteral("rootcmd ") + cmd;
}

QString scriptRootHelper() {
    // Absolute paths, not a PATH lookup: this app puts the account's own
    // `~/.local/bin` and `~/bin` ahead of the system directories, and those are
    // writable by whatever runs as the account. A `pkexec` or `sudo` planted
    // there would run at the prompt this helper opens, with the arguments the
    // caller chose.
    return QStringLiteral(
        "rootcmd() {\n"
        "  if [ \"$(id -u)\" -eq 0 ]; then\n"
        "    \"$@\"\n"
        "  else\n"
        "    for helper in /usr/bin/pkexec /bin/pkexec /usr/bin/sudo /bin/sudo; do\n"
        "      if [ -x \"$helper\" ]; then\n"
        "        \"$helper\" \"$@\"\n"
        "        return\n"
        "      fi\n"
        "    done\n"
        "    echo \"rootcmd: neither pkexec nor sudo is installed\" >&2\n"
        "    return 127\n"
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
        // One row is one thing the user ticks, and every extra path rides along
        // in the `rm -rf` that row produces. Names that fold together are the
        // same leftover only when they are siblings: `~/.config/google-chrome`
        // and `~/.config/chromium` are one row, `~/.cache/foo` and
        // `~/.local/share/foo` are two, and a row that spanned both would
        // delete a directory the review never showed.
        const QString primaryDir = findings[primary].path.isEmpty()
            ? QString()
            : QFileInfo(findings[primary].path).absolutePath();
        auto isSibling = [&findings, &primaryDir](int i) {
            const Finding &f = findings[i];
            if (QFileInfo(f.path).absolutePath() != primaryDir) return false;
            for (const QString &extra : f.extraPaths) {
                if (QFileInfo(extra).absolutePath() != primaryDir) return false;
            }
            return true;
        };
        bool allSiblings = true;
        for (int i : idx) {
            if (!isSibling(i)) {
                allSiblings = false;
                break;
            }
        }
        if (!allSiblings) continue;
        // A member with no measurement (`bytes < 0`) leaves the merged total
        // unknown. Summing the rest anyway prints a partial sum as if it were
        // the whole group, which is what the CLI's `sizeMeasured` flag avoids.
        bool allSized = true;
        for (int i : idx) {
            if (findings[i].bytes < 0) allSized = false;
        }
        for (int i : idx) {
            if (i == primary) continue;
            if (!findings[i].path.isEmpty()) findings[primary].extraPaths << findings[i].path;
            findings[primary].extraPaths << findings[i].extraPaths;
            findings[primary].bytes = addSatBytes(findings[primary].bytes, findings[i].bytes);
            drop.insert(i);
        }
        if (!allSized) findings[primary].bytes = -1;
        findings[primary].extraPaths.removeDuplicates();
        // The primary path is dropped from the sibling list by identity, not by
        // spelling, so a group whose members came off a decomposed mount does
        // not keep a second copy of its own path.
        findings[primary].extraPaths.removeIf([&](const QString &p) {
            return pathIdentityKey(p) == pathIdentityKey(findings[primary].path);
        });
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

/// Leftover dirs are not unused apps, and an outdated row is not either, so
/// both are excluded. The tier check is the path a plugin takes without a
/// dedicated kind, and it only applies to a row the scan could date: a
/// `review` or `remove` row with no `idleDays`, `mtime`, or `lastUsed` stays
/// off this page whatever tier it carries.
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
    return false;
}

void enrichLeftoverUsageTiming(Finding &f, const QDateTime &now) {
    if (!isLeftover(f) || isShadowFinding(f) || hasUsageTiming(f) || f.path.isEmpty()) return;
    const QFileInfo fi(f.path);
    if (!fi.exists()) return;
    const QDateTime mt = fi.lastModified();
    if (!mt.isValid()) return;
    f.mtime = mt.toUTC().toString(Qt::ISODate);
    // A negative count is an mtime ahead of now (a restored archive, a clock
    // that ran ahead), not an age of zero: clamping it to 0 makes
    // relativeDayLabel answer "Today" for a file the user has not touched in
    // whatever the archive was taken at. -1 is the same "could not be read"
    // the column already prints as unknown, and the mtime above still dates the
    // row on its own.
    const qint64 days = localCalendarDaysSince(mt, now);
    f.idleDays = days < 0 ? -1 : days;
}

void enrichFindingsUsageTiming(QVector<Finding> &findings, const QDateTime &now) {
    for (Finding &f : findings) enrichLeftoverUsageTiming(f, now);
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
        if (leftoverStatusBlocksCleanup(f.status)) continue;
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
            total = addSatBytes(total, n);
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
    // NFC for the same reason `searchFold` gives it: both sides of a group
    // key and of a desktop-stem match come off a filesystem, and an exFAT,
    // NTFS, or SMB share hands back the decomposed spelling. Without it a
    // leftover and its .desktop file never meet.
    token = searchFold(token);
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
            const QString low = searchFold(file);
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
        // Only "keep" is *written* here, so that is the only status worth
        // short-circuiting. An already-owned or already-system row must still be
        // offered to the desktop list: the set of installed desktop stems is
        // read once and this pass runs over the whole accumulated scan on every
        // plugin blob, so skipping them would leave a row that a desktop file
        // does match still marked orphaned.
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
        if (leftoverStatusBlocksCleanup(f.status)) return false;
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
    // The note is a fact about the scan, not about any one row: a command
    // that did not answer, or a list longer than the plugin's table, means
    // every row below is short of the machine. It rides on dialogBody and is
    // appended to the row's own reason, because the reason is what the user
    // reads next to the checkbox they are about to tick, and burying the note
    // under it is how an incomplete list gets confirmed as a complete one.
    if (!note.isEmpty()) {
        if (!dialogBody.isEmpty()) {
            dialogBody += QLatin1Char('\n');
        }
        dialogBody += QStringLiteral("Scan incomplete: ") + note;
    }
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
        if (!dialogBody.isEmpty() && row.dialogBody != dialogBody) {
            row.dialogBody += QLatin1Char('\n') + dialogBody;
        }
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
    // `dpkg` rc rows are marked with `apt-mark manual` on both platforms, the
    // same as `apt` orphans. The manager that emitted them is not the one that
    // owns the mark.
    return m == QLatin1String("apt") || m == QLatin1String("dpkg")
        || m == QLatin1String("pacman") || m == QLatin1String("dnf")
        || m == QLatin1String("zypper");
}

QString markManualCommand(const Finding &f) {
    if (!canMarkManual(f)) return {};
    // A leading `-` reaches the manager as an option, not as the package name.
    // The name comes from a registry, a tap, or the scan cache, so refuse it
    // rather than quoting it into a different command. Mirrors Swift
    // `isSafeCommandArgument`; the stricter Zig `jsonbuf.isSafeCmdIdent` also
    // runs, in the plugin that produced the name.
    const QString name = displayName(f);
    if (name.isEmpty() || name.startsWith(QLatin1Char('-'))) return {};
    const QString q = shellQuote(name);
    const QString m = distroManager(f);
    if (m == QLatin1String("apt") || m == QLatin1String("dpkg")) {
        return QStringLiteral("apt-mark manual ") + q;
    }
    if (m == QLatin1String("pacman")) return QStringLiteral("pacman -D --asexplicit ") + q;
    if (m == QLatin1String("dnf")) return QStringLiteral("dnf mark install ") + q;
    if (m == QLatin1String("zypper")) return QStringLiteral("zypper --non-interactive install ") + q;
    return {};
}

bool canMarkCleanup(const Finding &f, Page page) {
    if (page == Page::Outdated) {
        return f.updatable;
    }
    // A blocked status answers the question on its own, for a leftover and for
    // anything else alike. `leftoverCleanupCommand` refuses the same set, so
    // the leftover branch below already turned an `owned` or `system` row
    // untickable by accident of its command coming back empty; asking the
    // status first is what makes that deliberate rather than incidental.
    if (leftoverStatusBlocksCleanup(f.status)) return false;
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

QString searchHaystack(const Finding &f) {
    QString hay;
    hay.reserve(256);
    hay += displayName(f);
    hay += QLatin1Char('\n');
    hay += f.path;
    hay += QLatin1Char('\n');
    hay += f.kind;
    hay += QLatin1Char('\n');
    hay += managerLabel(f);
    hay += QLatin1Char('\n');
    hay += f.status;
    hay += QLatin1Char('\n');
    hay += f.packagedPath;
    hay += QLatin1Char('\n');
    hay += f.summary;
    hay += QLatin1Char('\n');
    hay += f.reason;
    for (const QString &p : f.extraPaths) {
        hay += QLatin1Char('\n');
        hay += p;
    }
    return searchFold(hay);
}
