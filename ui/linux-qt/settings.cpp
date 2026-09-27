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
#include <QSet>
#include <QSettings>
#include <QStandardPaths>
#include <QVariant>

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
    if (o.contains(QLatin1String("confirmDelete")) && !o.value(QLatin1String("confirmDelete")).isNull()) {
        const QJsonValue v = o.value(QLatin1String("confirmDelete"));
        if (!v.isBool()) {
            if (err) *err = QStringLiteral("confirmDelete must be true or false");
            return false;
        }
        s.confirmDelete = v.toBool();
    }
    if (o.contains(QLatin1String("includeSystem")) && !o.value(QLatin1String("includeSystem")).isNull()) {
        const QJsonValue v = o.value(QLatin1String("includeSystem"));
        if (!v.isBool()) {
            if (err) *err = QStringLiteral("includeSystem must be true or false");
            return false;
        }
        s.includeSystem = v.toBool();
    }
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
