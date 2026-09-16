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
/* Inverse of the engine/module cache the host keeps: call when the owner of the
   scans is disposed. */
void shutdownCoreWasm();
void clearCoreWasmCancel();

/* Inverse of the PATH rewrite taggedPluginSpecs makes. runCoreWasm already
   restores on every return; this covers a worker that was terminated before
   it could return. Safe to call when nothing was applied. */
void restoreCoreWasmPath();

#endif
