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
    bool isCancelled() const { return m_wanted.loadAcquire() != m_token.loadAcquire(); }
public slots:
    void run(const QString &core, const QStringList &pluginSpecs, int token) {
        m_token.storeRelease(token);
        /* One reference instant for the whole scan. Read per row instead, a
           scan that runs across local midnight dates the rows before it and
           the rows after it against two different days, and the same scan
           replayed an hour later stores a different idle count. */
        m_scanNow = QDateTime::currentDateTime();
        /* The installed `.desktop` stems are a fact about the machine, not
           about any one plugin, so they are read once here and reused by every
           plugin's ingest. Reading them per blob re-walked six application
           directories once per plugin. */
        m_desktopStems = installedDesktopStems();
        /* Clear first so every exit path below leaves the process-global cancel
           clear. */
        clearCoreWasmCancel();
        if (isCancelled()) {
            emit finished(QVector<Finding>(), QStringLiteral("Scan cancelled."), 1, QStringList());
            return;
        }
        ScanAccum acc;
        acc.worker = this;
        m_partial.clear();
        m_notes.clear();
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
            emit finished(QVector<Finding>(), QStringLiteral("Scan cancelled."), 1, QStringList());
            return;
        }
        emit finished(m_partial, QString::fromUtf8(err), rc, m_notes);
    }
signals:
    void progress(const QString &pluginId, int index, int total);
    /// The rows that exist so far, after every plugin that just reported. The
    /// window draws them while the rest of the plugins are still running.
    void partial(const QVector<Finding> &findings);
    /// The run's rows, its stderr, its exit status, and the plugin-level notes
    /// it collected. The notes ride on the signal rather than being read off
    /// the worker from the window thread: the argument copy is what publishes
    /// the run's writes, the same way `findings` is published.
    void finished(const QVector<Finding> &findings, const QString &err, int rc,
                  const QStringList &notes);

private:
    /// Enrich one plugin's findings and publish the running total. The order
    /// is timing, then owned-path status, then sibling grouping, so a partial
    /// list never disagrees with the final one on the rows it already has.
    void ingestBlob(const char *json, size_t len) {
        QVector<Finding> batch;
        appendFindingsFromBlob(batch, QByteArray(json, int(len)), &m_notes);
        /* A note is collected before the empty-batch return: a plugin that
           answers with no findings and a note has said the page is short of
           the machine, and returning first is how that word was dropped. */
        if (batch.isEmpty()) return;
        enrichFindingsUsageTiming(batch, m_scanNow);
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
        if (anyLeftover) markOwnedPathLeftovers(m_partial, m_desktopStems);
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
    /// Written by the scan thread at the start of a run and read by the window
    /// thread through isCancelled, and by the leftover-size threads that poll
    /// the same callback. The token it is compared to, so it is atomic too: a
    /// plain int read there is a data race, and a cancel that lands mid-scan
    /// can compare against a half-updated value and miss the run it meant to
    /// stop. Same shape as DiskScanWorker::m_token.
    QAtomicInteger<int> m_token{0};
    QDateTime m_scanNow;
    /// The installed desktop stems, read once per scan on the scan thread. Only
    /// `run` (the scan thread) and the `ingestBlob` calls it makes during that
    /// same synchronous `runCoreWasm` touch it, so no lock is needed.
    QSet<QString> m_desktopStems;
    QVector<Finding> m_partial;
    /// The plugin-level notes this run collected, read by the window when it
    /// takes the `finished` signal this same thread emits. Scan-level, like
    /// Swift's `ScanData.incomplete`: it says the run as a whole is short of
    /// the machine, not that any one row is.
    QStringList m_notes;
};

#endif
