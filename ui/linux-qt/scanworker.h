#ifndef APPATTIC_SCANWORKER_H
#define APPATTIC_SCANWORKER_H

#include "corehost.h"
#include "finding.h"

#include <QAtomicInteger>
#include <QByteArray>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVector>

/* The thread that drives the WASM core and hands findings back to the window.
   It owns no widget: main.cpp holds the window, this holds the scan. */

class ScanWorker;

struct ScanAccum {
    ScanWorker *worker = nullptr;
};

class ScanWorker : public QObject {
    Q_OBJECT
public:
    void setWanted(int token) { m_wanted.storeRelease(token); }
    void requestCancel() {
        m_wanted.storeRelease(0);
        requestCoreWasmCancel();
    }
    bool isCancelled() const { return m_wanted.loadAcquire() != m_token; }
public slots:
    void run(const QString &core, const QStringList &pluginSpecs, int token) {
        m_token = token;
        /* Clear first so every exit path below leaves the process-global cancel
           clear; the previous order left it armed when the run never started. */
        clearCoreWasmCancel();
        if (isCancelled()) {
            emit finished(QVector<Finding>(), QStringLiteral("Scan cancelled."), 1);
            return;
        }
        ScanAccum acc;
        acc.worker = this;
        m_partial.clear();
        char err[1024];
        err[0] = '\0';
        const int rc = runCoreWasm(
            core,
            pluginSpecs,
            scanOnJson,
            &acc,
            err,
            sizeof err,
            scanOnProgress
        );
        if (isCancelled()) {
            emit finished(QVector<Finding>(), QStringLiteral("Scan cancelled."), 1);
            return;
        }
        emit finished(m_partial, QString::fromUtf8(err), rc);
    }
signals:
    void progress(const QString &pluginId, int index, int total);
    /// The rows that exist so far, after every plugin that just reported. The
    /// window draws them while the rest of the plugins are still running.
    void partial(const QVector<Finding> &findings);
    void finished(const QVector<Finding> &findings, const QString &err, int rc);

private:
    /// Enrich one plugin's findings and publish the running total. Order
    /// matches the old single pass at the end: timing, then owned-path status,
    /// then sibling grouping, so a partial list never disagrees with the final
    /// one on the rows it already has.
    void ingestBlob(const char *json, size_t len) {
        QVector<Finding> batch;
        appendFindingsFromBlob(batch, QByteArray(json, int(len)));
        if (batch.isEmpty()) return;
        enrichFindingsUsageTiming(batch);
        bool anyLeftover = false;
        for (const Finding &f : batch) {
            if (isLeftover(f)) {
                anyLeftover = true;
                break;
            }
        }
        if (anyLeftover) {
            auto cancelled = [](void *user) -> bool {
                return static_cast<ScanWorker *>(user)->isCancelled();
            };
            enrichLeftoverSizes(batch, cancelled, this);
            if (isCancelled()) return;
        }
        m_partial += batch;
        if (anyLeftover) markOwnedPathLeftovers(m_partial);
        groupLinuxLeftovers(m_partial);
        emit partial(m_partial);
    }

    static void scanOnJson(const char *json, size_t len, void *user) {
        auto *acc = static_cast<ScanAccum *>(user);
        if (!acc || !json || !acc->worker) return;
        acc->worker->ingestBlob(json, len);
    }

    static void scanOnProgress(const char *pluginId, int index, int total, void *user) {
        auto *acc = static_cast<ScanAccum *>(user);
        if (!acc || !pluginId || !acc->worker) return;
        emit acc->worker->progress(QString::fromUtf8(pluginId), index, total);
    }

    QAtomicInteger<int> m_wanted{0};
    int m_token = 0;
    QVector<Finding> m_partial;
};

#endif
