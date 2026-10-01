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

/// The file a restore replaced, and the restore that puts the backup back.
/// The backup is the only copy of the ignore list once settings.json stops
/// reading, so putting it back is a destructive step on a machine that is
/// already broken: `restoreSettingsBackup` parses the backup with the same
/// loader the window reads settings with and changes nothing if it does not
/// parse, and keeps whatever was in settings.json as `settings.json.bad`, so a
/// restore that turns out to be the wrong state is not a second loss. The Swift
/// `restoreSettingsBackup` keeps the same two files, so both windows, the CLI
/// and the macOS UI leave the same three files next to each other.
QString settingsRejectedPath(const QString &settingsPath);
bool restoreSettingsBackup(const QString &settingsPath, QString *err);

/// Replace `path` with `raw` whole or not at all, and only report success once
/// the bytes are on disk. The rename a save is made of publishes the file while
/// its contents are still in the page cache, so without the fsync a crash can
/// leave a correctly named settings file holding a truncated write. A file that
/// cannot be made durable is removed rather than published, which leaves the
/// copy the write took of the state it replaced as the state on disk.
bool writeDurableFile(const QByteArray &raw, const QString &path);

#endif
