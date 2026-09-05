#include "settings.h"

#include <QDir>
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
    const QByteArray xdg = qgetenv("XDG_DATA_HOME");
    const QString configured = QString::fromUtf8(xdg).trimmed();
    const QString base = QDir::isAbsolutePath(configured)
        ? configured
        : (QDir::homePath() + QStringLiteral("/.local/share"));
    return QDir(base).filePath(QStringLiteral("appattic/settings.json"));
}

static bool legacyBool(const QSettings &qs, const QString &key, bool fallback) {
    if (!qs.contains(key)) return fallback;
    const QVariant v = qs.value(key);
    if (v.userType() == QMetaType::Bool) return v.toBool();
    const QString t = v.toString().trimmed().toLower();
    if (t == QLatin1String("true") || t == QLatin1String("1") || t == QLatin1String("yes")) {
        return true;
    }
    if (t == QLatin1String("false") || t == QLatin1String("0") || t == QLatin1String("no")) {
        return false;
    }
    return fallback;
}

AppSettings migrateLegacyQSettings(bool *hadValues) {
    QSettings qs(QStringLiteral("AppAttic"), QStringLiteral("AppAttic"));
    const bool present = qs.contains(QStringLiteral("confirmDelete"))
        || qs.contains(QStringLiteral("includeSystem"))
        || qs.contains(QStringLiteral("ignoredLeftovers"));
    if (hadValues) *hadValues = present;
    AppSettings s;
    if (!present) return s;
    s.confirmDelete = legacyBool(qs, QStringLiteral("confirmDelete"), true);
    s.includeSystem = legacyBool(qs, QStringLiteral("includeSystem"), false);
    const QStringList ign = qs.value(QStringLiteral("ignoredLeftovers")).toStringList();
    QSet<QString> seen;
    for (const QString &raw : ign) {
        const QString p = raw.normalized(QString::NormalizationForm_C);
        if (p.isEmpty() || seen.contains(p)) continue;
        seen.insert(p);
        s.ignoredLeftoverPaths.append(p);
    }
    return s;
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
    QStringList paths;
    QSet<QString> seen;
    for (const QString &raw : s.ignoredLeftoverPaths) {
        const QString p = raw.normalized(QString::NormalizationForm_C);
        if (p.isEmpty() || seen.contains(p)) continue;
        seen.insert(p);
        paths.append(p);
    }
    paths.sort();
    for (const QString &p : paths) ign.append(p);
    o.insert(QStringLiteral("ignoredLeftoverPaths"), ign);
    o.insert(QStringLiteral("includeSystem"), s.includeSystem);
    return QJsonDocument(o).toJson(QJsonDocument::Indented);
}
