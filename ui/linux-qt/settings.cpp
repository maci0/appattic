#include "settings.h"

#include "finding.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QMetaType>
#include <QSaveFile>
#include <QSet>
#include <QSettings>
#include <QStandardPaths>
#include <QVariant>

#include <fcntl.h>
#include <unistd.h>

namespace {

/// The file's bytes are on disk. QSaveFile replaces by rename, and a rename
/// publishes a file whose contents are still in the page cache, so a crash
/// between the two leaves a correctly named file holding a truncated write.
/// The state written here is the account's own choices, which no scan can
/// rebuild, so the save is not a save until the bytes are. The Swift scanner's
/// `writeOwnerOnlyFile` does this for the same file from the CLI and the macOS
/// window.
bool syncWrittenFile(const QString &path) {
    // `toUtf8`, not `toLocal8Bit`. `QSaveFile` above opens this same path
    // through Qt, which encodes a file name as UTF-8 on every platform Qt
    // supports on Linux; `toLocal8Bit` encodes it in the *system locale*, so
    // under a latin-1 locale the two name two different bytes and this
    // `::open` reaches a file that is not the one just written — or none. The
    // fsync then reports success for a path that was never flushed, or fails
    // and deletes a settings file that is correct on disk.
    const QByteArray cPath = path.toUtf8();
    const int fd = ::open(cPath.constData(), O_RDONLY);
    if (fd < 0) return false;
    const bool synced = ::fsync(fd) == 0;
    ::close(fd);
    if (!synced) return false;
    // The directory entry naming the new file is in the page cache until the
    // directory itself is written out, so a crash here can leave the
    // destination as it was before the write. That is not the file's failure
    // to write: the bytes are on disk and the name resolves, and reporting it
    // would make a durable write look like a failed one. A directory that
    // cannot be opened for fsync at all (some network mounts) is as durable as
    // that filesystem can make it.
    const QByteArray cDir = QFileInfo(path).absolutePath().toUtf8();
    const int dir = ::open(cDir.constData(), O_RDONLY | O_DIRECTORY);
    if (dir < 0) return true;
    ::fsync(dir);
    ::close(dir);
    return true;
}

} // namespace

/// Write `raw` to `path` whole or not at all, and leave it on disk. The
/// temporary file is created at `0600` and is the destination from the rename
/// on, so nothing sees the file at the umask default the way a write followed
/// by a chmod does. A file that cannot be made durable is removed rather than
/// published: the caller is told the write failed, and the copy the write took
/// of the state it replaced is what is left.
bool writeDurableFile(const QByteArray &raw, const QString &path) {
    QSaveFile out(path);
    if (!out.open(QIODevice::WriteOnly)) return false;
    if (!out.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner)) {
        out.cancelWriting();
        return false;
    }
    if (out.write(raw) != raw.size()) {
        out.cancelWriting();
        return false;
    }
    if (!out.commit()) return false;
    if (syncWrittenFile(path)) return true;
    QFile::remove(path);
    return false;
}

QString settingsFilePath() {
    return QDir(QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation))
        .filePath(QStringLiteral("appattic/settings.json"));
}

QString scanCacheFilePath() {
    return QDir(QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation))
        .filePath(QStringLiteral("appattic/last-scan.json"));
}

/// Drop the scan snapshot the CLI and the macOS UI reuse. This UI scans live and
/// keeps no snapshot of its own, but the two are the same file, so a cleanup
/// that removes files or changes package state has to invalidate it here too:
/// the fingerprint in it does not move when a file inside a scanned directory
/// is deleted, so the next CLI run would otherwise serve rows for items that
/// are already gone. Absent is the wanted state, so a file that is not there is
/// not a failure.
bool removeScanCacheFile(const QString &path) {
    if (path.isEmpty() || !QFile::exists(path)) return true;
    return QFile::remove(path);
}

bool legacyBoolValue(const QVariant &value, bool fallback, bool *readable) {
    if (readable) *readable = true;
    if (value.userType() == QMetaType::Bool) return value.toBool();
    const QString t = value.toString().trimmed().toLower();
    if (t == QLatin1String("true") || t == QLatin1String("1") || t == QLatin1String("yes")) {
        return true;
    }
    if (t == QLatin1String("false") || t == QLatin1String("0") || t == QLatin1String("no")) {
        return false;
    }
    if (readable) *readable = false;
    return fallback;
}

static bool legacyBool(const QSettings &qs, const QString &key, bool fallback, QStringList *unreadable) {
    if (!qs.contains(key)) return fallback;
    bool readable = true;
    const bool v = legacyBoolValue(qs.value(key), fallback, &readable);
    if (!readable && unreadable) unreadable->append(key);
    return v;
}

AppSettings migrateLegacyQSettings(bool *hadValues, QStringList *unreadable, QString *legacyPath) {
    QSettings qs(QStringLiteral("AppAttic"), QStringLiteral("AppAttic"));
    const bool present = qs.contains(QStringLiteral("confirmDelete"))
        || qs.contains(QStringLiteral("includeSystem"))
        || qs.contains(QStringLiteral("ignoredLeftovers"));
    if (hadValues) *hadValues = present;
    if (unreadable) unreadable->clear();
    if (legacyPath) *legacyPath = qs.fileName();
    AppSettings s;
    if (!present) return s;
    s.confirmDelete = legacyBool(qs, QStringLiteral("confirmDelete"), true, unreadable);
    s.includeSystem = legacyBool(qs, QStringLiteral("includeSystem"), false, unreadable);
    const QStringList ign = qs.value(QStringLiteral("ignoredLeftovers")).toStringList();
    QSet<QString> seen;
    for (const QString &raw : ign) {
        const QString p = raw.normalized(QString::NormalizationForm_C);
        if (p.isEmpty() || seen.contains(p)) continue;
        // Migrating writes this list into settings.json, which the JSON loader
        // refuses to read back if an entry is not absolute. Report the key and
        // let the caller stop, the same way an unreadable boolean stops it.
        if (!p.startsWith(QLatin1Char('/')) || p.endsWith(QLatin1Char('/'))) {
            if (unreadable) unreadable->append(QStringLiteral("ignoredLeftovers"));
            break;
        }
        seen.insert(p);
        s.ignoredLeftoverPaths.append(p);
    }
    // The legacy file holds the ignore list: absolute paths under the
    // account's own home directory. QSettings wrote it at the umask default
    // (`0644`), so every local account on the machine could read them. Once the
    // migration lands in settings.json the caller deletes the file outright
    // (removeLegacySettingsFile), so the mode here covers the window between
    // the read and that delete, and the case where the migration is blocked
    // and the file stays as the one the error message tells the user to edit.
    restrictOwnerOnlyFile(qs.fileName());
    return s;
}

bool removeLegacySettingsFile(const QString &path) {
    if (path.isEmpty() || !QFile::exists(path)) return true;
    return QFile::remove(path);
}

bool parseSettingsJson(const QByteArray &raw, AppSettings *out, QString *err) {
    if (raw.isEmpty()) {
        if (err) *err = QStringLiteral("file is empty");
        return false;
    }
    QJsonParseError pe;
    const QJsonDocument doc = QJsonDocument::fromJson(raw, &pe);
    if (pe.error != QJsonParseError::NoError) {
        if (err) *err = QStringLiteral("not valid JSON");
        return false;
    }
    if (!doc.isObject()) {
        if (err) *err = QStringLiteral("root must be a JSON object");
        return false;
    }
    const QJsonObject o = doc.object();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        if (it.key() != QLatin1String("confirmDelete")
            && it.key() != QLatin1String("ignoredLeftoverPaths")
            && it.key() != QLatin1String("includeSystem")) {
            if (err) *err = QStringLiteral("unknown key: %1").arg(it.key());
            return false;
        }
    }
    AppSettings s;
    // A missing key and an explicit null both leave the default in place, and
    // a present key of the wrong type is a file to refuse, not to coerce.
    auto readBool = [&](const QLatin1String &key, bool *slot) {
        if (!o.contains(key) || o.value(key).isNull()) return true;
        const QJsonValue v = o.value(key);
        if (!v.isBool()) {
            if (err) *err = QStringLiteral("%1 must be true or false").arg(key);
            return false;
        }
        *slot = v.toBool();
        return true;
    };
    if (!readBool(QLatin1String("confirmDelete"), &s.confirmDelete)) return false;
    if (!readBool(QLatin1String("includeSystem"), &s.includeSystem)) return false;
    if (o.contains(QLatin1String("ignoredLeftoverPaths"))
        && !o.value(QLatin1String("ignoredLeftoverPaths")).isNull()) {
        const QJsonValue v = o.value(QLatin1String("ignoredLeftoverPaths"));
        if (!v.isArray()) {
            if (err) *err = QStringLiteral("ignoredLeftoverPaths must be an array of strings");
            return false;
        }
        QSet<QString> seen;
        for (const QJsonValue &item : v.toArray()) {
            if (!item.isString()) {
                if (err) *err = QStringLiteral("ignoredLeftoverPaths must be an array of strings");
                return false;
            }
            const QString p = item.toString().normalized(QString::NormalizationForm_C);
            if (p.isEmpty() || seen.contains(p)) continue;
            // Matched against the leftover path a scan reports, so a relative
            // entry or a `~` one hides nothing and says so nowhere. The Swift
            // loader refuses it too; a file one of the two accepts and the
            // other rejects is a file the user cannot reason about.
            if (!p.startsWith(QLatin1Char('/'))) {
                if (err) *err = QStringLiteral("ignoredLeftoverPaths entry \"%1\" is not an absolute path; use the full path, the one the report prints").arg(p);
                return false;
            }
            if (p.endsWith(QLatin1Char('/'))) {
                if (err) *err = QStringLiteral("ignoredLeftoverPaths entry \"%1\" has a trailing slash; use the full path, the one the report prints").arg(p);
                return false;
            }
            seen.insert(p);
            s.ignoredLeftoverPaths.append(p);
        }
    }
    if (out) *out = s;
    return true;
}

QString settingsBackupPath(const QString &settingsPath) {
    return settingsPath + QStringLiteral(".bak");
}

bool keepSettingsBackup(const QString &settingsPath) {
    if (settingsPath.isEmpty() || !QFile::exists(settingsPath)) return true;
    QFile in(settingsPath);
    if (!in.open(QIODevice::ReadOnly)) return false;
    const QByteArray raw = in.readAll();
    in.close();
    if (raw.isEmpty()) return true;
    /* A file the backup already holds is not copied again. persistSettings
       runs on every toggle, a double click reaches the handler twice, and a
       window that re-saves what it loaded writes the same bytes; copying them
       would leave the backup holding a copy of the file already there, and the
       last state that differed from the current one would be gone. The Swift
       saveSettings makes the same comparison. */
    {
        QFile kept(settingsBackupPath(settingsPath));
        if (kept.open(QIODevice::ReadOnly) && kept.readAll() == raw) return true;
    }
    if (!writeDurableFile(raw, settingsBackupPath(settingsPath))) return false;
    restrictPrivateDataFile(settingsBackupPath(settingsPath));
    return true;
}

QString settingsRejectedPath(const QString &settingsPath) {
    return settingsPath + QStringLiteral(".bad");
}

bool restoreSettingsBackup(const QString &settingsPath, QString *err) {
    if (settingsPath.isEmpty()) {
        if (err) *err = QStringLiteral("no settings file to restore");
        return false;
    }
    const QString backup = settingsBackupPath(settingsPath);
    if (!QFile::exists(backup)) {
        if (err) *err = QStringLiteral("there is no settings backup at %1 to restore").arg(backup);
        return false;
    }
    QFile in(backup);
    if (!in.open(QIODevice::ReadOnly)) {
        if (err) *err = QStringLiteral("could not read the settings backup at %1").arg(backup);
        return false;
    }
    const QByteArray raw = in.readAll();
    in.close();
    /* The parse is the check, and it is the window's own loader: a backup that
       reads here is a backup the window will read, so the restore cannot be
       the step that leaves the settings unreadable. The copy has no such step,
       which is why a copy is not what this does. */
    AppSettings restored;
    QString parseErr;
    if (!parseSettingsJson(raw, &restored, &parseErr)) {
        if (err) *err = QStringLiteral("the settings backup at %1 is not usable (%2); nothing was changed")
                            .arg(backup, parseErr);
        return false;
    }
    const QByteArray encoded = encodeSettingsJson(restored);
    /* Keep the state this restore replaces before it replaces it. Absent is
       not a failure: then the wanted state is a fresh settings.json. A restore
       that would write back the same bytes keeps nothing, or the file a
       restore already kept is lost to a copy of the file that is already
       there. */
    QFile current(settingsPath);
    if (current.open(QIODevice::ReadOnly)) {
        const QByteArray before = current.readAll();
        current.close();
        if (!before.isEmpty() && before != encoded) {
            if (!writeDurableFile(before, settingsRejectedPath(settingsPath))) {
                if (err) *err = QStringLiteral("could not keep the settings file being replaced; nothing was changed");
                return false;
            }
            restrictPrivateDataFile(settingsRejectedPath(settingsPath));
        }
    }
    if (!writeDurableFile(encoded, settingsPath)) {
        if (err) *err = QStringLiteral("could not write settings to %1").arg(settingsPath);
        return false;
    }
    return true;
}

QByteArray encodeSettingsJson(const AppSettings &s) {
    QJsonObject o;
    o.insert(QStringLiteral("confirmDelete"), s.confirmDelete);
    QJsonArray ign;
    QSet<QString> seen;
    // Paths are normalized and deduplicated, otherwise as given. The caller's
    // list comes from a QSet, so it arrives in hash order, not in the order the
    // user entered it; nothing here re-sorts it.
    for (const QString &raw : s.ignoredLeftoverPaths) {
        const QString p = raw.normalized(QString::NormalizationForm_C);
        if (p.isEmpty() || seen.contains(p)) continue;
        seen.insert(p);
        ign.append(p);
    }
    o.insert(QStringLiteral("ignoredLeftoverPaths"), ign);
    o.insert(QStringLiteral("includeSystem"), s.includeSystem);
    return QJsonDocument(o).toJson(QJsonDocument::Indented);
}
