#ifndef APPATTIC_SCRIPTPROC_H
#define APPATTIC_SCRIPTPROC_H

#include <QByteArray>
#include <QObject>
#include <QString>

class QProcess;
class QTimer;

/// Delete a run's generated script, and say whether it went. `keepPath` takes
/// the path when the file survived, so the caller can name it and try again;
/// it is left alone when the removal landed. Not being there any more is the
/// state the delete wanted, so a removal raced by something else is not a
/// failure. Exposed for the helper tests, which pin the three cases: a
/// survivor is reported and kept, a file that is gone is success, and an empty
/// path is not a removal to fail.
bool removeScriptFile(const QString &path, QString &keepPath);

/// How long a generated cleanup, update, or mark-manual script may run before
/// it is stopped, and the whole minutes the stop message reports. Exposed so
/// the window cannot state a deadline the runner does not apply. See
/// scriptproc.cpp for why the bound exists.
extern const int kScriptTimeoutMs;
extern const int kScriptTimeoutMinutes;

/// Runs one generated cleanup, update, or mark-manual script under `/bin/sh`
/// and owns everything about that run that is not presentation: the temp file,
/// the process group, the deadline, and the capped output tail. The window
/// decides what to show and when a rescan is due; this decides how a script
/// starts, is stopped, and is reported.
class ScriptProcess : public QObject {
    Q_OBJECT

public:
    explicit ScriptProcess(QObject *parent = nullptr);
    ~ScriptProcess() override;

    /// Write `script` to a temp file and set the run up. `errorText` is set and
    /// false is returned when the file cannot be written.
    ///
    /// `start()` is separate so the caller can connect to `finished` and
    /// `failed` first: a script that dies the moment it is spawned would
    /// otherwise report into a window that is not listening yet.
    bool prepare(const QString &script, QString *errorText);

    /// Run the prepared script under `/bin/sh`.
    void start();

    /// The deadline fired or the user asked: SIGTERM, then SIGKILL after the
    /// grace period. `finished` still reports the run, so the caller does not
    /// have to unwind anything here.
    void stop();

    /// Whether a script is running.
    bool running() const { return m_proc != nullptr; }

    /// The accumulated output, capped and cut on a UTF-8 boundary.
    const QByteArray &output() const { return m_output; }

    /// A run's script that could not be removed from the temp directory, or
    /// empty when the last one is gone. It is an executable holding the `rm`
    /// lines the run was about to execute, so the window names it rather than
    /// leaving the user to find it. Empty once the destructor's own attempt has
    /// landed.
    QString scriptLeftBehind() const { return m_path; }

signals:
    /// The process is gone. `stopped` says the deadline, not the exit status,
    /// is why; `output` is everything the run printed.
    void finished(int exitCode, bool stopped, const QByteArray &output);

    /// `/bin/sh` never started. No exit status exists, so this is not a
    /// `finished` with a made-up code.
    void failed();

private:
    /// Delete `path` and keep the result on `m_path` when it is the current
    /// run's script and the removal did not land, so the destructor makes
    /// another attempt. Forgets the path once the file is gone.
    void removeRunScript(const QString &path);

    void appendOutput(const QByteArray &chunk);

    QProcess *m_proc = nullptr;
    QTimer *m_timer = nullptr;
    bool m_stopped = false;
    /// The run has been reported. `stop` reports a script that outlives both
    /// signals itself, so the `finished` that arrives later, if it ever does,
    /// must not report the same run twice.
    bool m_reported = false;
    QString m_path;
    QByteArray m_output;
};

#endif
