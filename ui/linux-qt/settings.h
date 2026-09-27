#ifndef APPATTIC_QT_SETTINGS_H
#define APPATTIC_QT_SETTINGS_H

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QVariant>

struct AppSettings {
    bool includeSystem = false;
    bool confirmDelete = true;
    QStringList ignoredLeftoverPaths;
};

QString settingsFilePath();

/// The scan snapshot the CLI and the macOS UI reuse, under the same data
/// directory. This UI does not read or write it, but it deletes what the
/// snapshot describes, so it has to drop it.
QString scanCacheFilePath();
bool removeScanCacheFile(const QString &path);

/// Read a boolean out of a legacy QSettings value. A value that is not a
/// boolean sets `*readable` to false and leaves the answer at `fallback`; the
/// caller reports it instead of writing the fallback back as the user's
/// setting.
bool legacyBoolValue(const QVariant &value, bool fallback, bool *readable);

/// `hadValues` is set when legacy keys were present. `unreadable` collects the
/// keys whose stored value was not a boolean.
AppSettings migrateLegacyQSettings(bool *hadValues, QStringList *unreadable);
bool parseSettingsJson(const QByteArray &raw, AppSettings *out, QString *err);
QByteArray encodeSettingsJson(const AppSettings &s);

#endif
