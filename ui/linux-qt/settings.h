#ifndef APPATTIC_QT_SETTINGS_H
#define APPATTIC_QT_SETTINGS_H

#include <QByteArray>
#include <QString>
#include <QStringList>

struct AppSettings {
    bool includeSystem = false;
    bool confirmDelete = true;
    QStringList ignoredLeftoverPaths;
};

QString settingsFilePath();
AppSettings migrateLegacyQSettings(bool *hadValues);
bool parseSettingsJson(const QByteArray &raw, AppSettings *out, QString *err);
QByteArray encodeSettingsJson(const AppSettings &s);

#endif
