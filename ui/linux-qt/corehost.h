#ifndef APPATTIC_COREHOST_H
#define APPATTIC_COREHOST_H

#include <cstddef>
#include <QByteArray>
#include <QString>
#include <QStringList>

QString coreOutDir();
QStringList pluginWasmFiles(const QString &out);
QStringList taggedPluginSpecs(const QString &out);

int runCoreWasm(
    const QString &coreWasm,
    const QStringList &pluginSpecs,
    void (*onJson)(const char *json, size_t jsonLen, void *user),
    void *user,
    char *err,
    size_t errlen,
    void (*onProgress)(const char *pluginId, int index, int total, void *user) = nullptr
);

void requestCoreWasmCancel();
void clearCoreWasmCancel();

#endif
