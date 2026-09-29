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
/// keys whose stored value could not be carried over. `legacyPath` is the file
/// those values came from, which the caller has to name: a blocked migration is
/// only fixable by editing that file, and saving settings does not clear it.
AppSettings migrateLegacyQSettings(bool *hadValues, QStringList *unreadable, QString *legacyPath);

/// Delete the legacy QSettings file once its values are in settings.json.
/// Nothing reads the file after a successful migration, and it holds the
/// account's own paths, so leaving it behind keeps them on disk for a program
/// that no longer opens it. Absent is the wanted state, so a file that is not
/// there is not a failure. The caller runs this only after the new settings
/// are on disk: a migration that could not be written leaves the old file as
/// the copy the user has to edit.
bool removeLegacySettingsFile(const QString &path);

bool parseSettingsJson(const QByteArray &raw, AppSettings *out, QString *err);
QByteArray encodeSettingsJson(const AppSettings &s);

/// Where the last settings file this shell wrote is kept, and the copy that
/// puts it there. `settings.json` holds the user's own choices, so the state
/// before a replace has to outlive the write that replaces it. A file the
/// backup already holds is left alone, so a save that changed nothing cannot
/// replace that state with a copy of the current file. False when there was
/// nothing to copy or the copy did not land; the caller writes the new
/// settings either way, because a backup is not the write it asked for.
/// The Swift scanner's `saveSettings` keeps the same file.
QString settingsBackupPath(const QString &settingsPath);
bool keepSettingsBackup(const QString &settingsPath);

#endif
