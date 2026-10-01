#include "scriptproc.h"

#include <QDir>
#include <QFile>
#include <QProcess>
#include <QProcessEnvironment>
#include <QTemporaryFile>
#include <QTimer>

#include <csignal>
#include <cstdio>
#include <sys/types.h>
#include <unistd.h>

/// Bytes of script output kept for the failure report. The report itself shows
/// the last 400, so this only has to cover them with room for a whole line.
static const int kScriptOutputCap = 64 * 1024;

/// How long a generated cleanup, update, or mark-manual script may run before
/// it is stopped (`kScriptTimeoutMs`). The same bound the Swift runner applies
/// (`scriptRunTimeout`), and for the same reason: a script blocked on a stale
/// dpkg lock, an unreachable mirror, or a prompt nothing can answer otherwise
/// leaves every action disabled with only the busy bar to say so, and the
/// window is unusable until the app is killed. These scripts are not rolled
/// back, so a stop mid-run is reported as partial work, never as a clean
/// failure.
const int kScriptTimeoutMs = 600000;
const int kScriptTimeoutMinutes = kScriptTimeoutMs / 60000;

/// How long a stopped script gets to exit before it is killed. `sh` and the
/// package managers below it both handle SIGTERM, so this is only reached by a
/// process that is stuck rather than slow. It blocks the window for at most one
/// second, once, after the run has already spent ten minutes.
static const int kScriptStopGraceMs = 1000;

/// How long the destructor waits for a killed script to be reaped.
static const int kScriptReapMs = 3000;

/// Put a script in its own process group, so a stop reaches everything it
/// started. `QProcess::terminate` and `kill` signal the direct child only, and
/// the direct child is `/bin/sh`; the apt, pacman, or flatpak process it is
/// waiting on is a separate process and survives both. A stopped run would
/// then report a clean stop while that process kept holding the dpkg lock and
/// kept removing packages behind the window, and the next run would fail on the
/// lock the stopped one left. The host's own subprocesses are grouped the same
/// way (`core/host/hostexec.c`).
static void isolateScriptProcessGroup(QProcess *proc) {
    if (!proc) return;
    proc->setChildProcessModifier([] { ::setpgid(0, 0); });
}

/// Signal a grouped script and everything below it. Falls back to the direct
/// child when the group cannot be signalled, so a script whose group is gone
/// still gets stopped.
static void signalScriptGroup(QProcess *proc, int sig) {
    if (!proc) return;
    const qint64 pid = proc->processId();
    if (pid > 0 && ::kill(-static_cast<pid_t>(pid), sig) == 0) return;
    if (sig == SIGKILL) proc->kill();
    else proc->terminate();
}

/// Delete a run's script and say whether it went.
///
/// The file is a mode-0700 shell script whose body is the `rm -rf` lines the
/// user reviewed, and the name it has under the temp directory is not theirs
/// to guess. A removal that does not land leaves an executable that deletes the
/// listed paths, on disk, with nothing pointing at it, so the path is kept in
/// `keepPath` for the destructor to try again and reported to the caller
/// rather than dropped with the rest of the per-run state. Not being there any
/// more is the state the delete wanted, so a removal raced by something else
/// is not a failure.
bool removeScriptFile(const QString &path, QString &keepPath) {
    if (path.isEmpty()) return true;
    if (QFile::remove(path) || !QFile::exists(path)) return true;
    keepPath = path;
    return false;
}

ScriptProcess::ScriptProcess(QObject *parent) : ScriptProcess(kScriptTimeoutMs, parent) {}

ScriptProcess::ScriptProcess(int timeoutMs, QObject *parent) : QObject(parent), m_timeoutMs(timeoutMs) {
    // One timer for the object's life, not one per run: `prepare` is the entry
    // point a caller reuses, and a `new QTimer(this)` in it left the previous
    // one a child of this object, still holding its `timeout` connection, for
    // as long as the window stayed open.
    m_timer = new QTimer(this);
    m_timer->setSingleShot(true);
    connect(m_timer, &QTimer::timeout, this, &ScriptProcess::stop);
}

qint64 ScriptProcess::deadlineRemaining() const {
    if (!m_timer) return -1;
    const int left = m_timer->remainingTime();
    return left < 0 ? -1 : qint64(left);
}

ScriptProcess::~ScriptProcess() {
    if (m_timer) m_timer->stop();
    if (m_proc) {
        signalScriptGroup(m_proc, SIGKILL);
        m_proc->waitForFinished(kScriptReapMs);
        m_proc = nullptr;
    }
    // The script is written with autoRemove off, so the terminal paths own the
    // delete. Quitting mid-script is the third exit, and without it every quit
    // in that window leaves an executable full of rm lines in the temp
    // directory. This last attempt is the only one left, so a survivor is
    // named on stderr: the process is going away and there is no window to
    // put a banner in.
    if (!m_path.isEmpty()) {
        QString left;
        if (!removeScriptFile(m_path, left)) {
            std::fprintf(stderr, "appattic: could not remove the generated script %s\n",
                         qPrintable(left));
        }
        m_path.clear();
    }
}

/// Keep the tail of what the script printed, capped. A package transaction
/// runs for as long as the package manager takes and says so on every file it
/// touches, so an unbounded buffer grows with the run in a window that stays
/// open afterwards. The error report shows the last lines, which is where the
/// failure is, so dropping the front costs the report nothing.
void ScriptProcess::appendOutput(const QByteArray &chunk) {
    m_output += chunk;
    if (m_output.size() <= kScriptOutputCap) return;
    m_output = m_output.right(kScriptOutputCap);
    // The cut can land mid-character; the partial one at the front would decode
    // to a replacement character in the report.
    int start = 0;
    while (start < m_output.size()
           && (static_cast<unsigned char>(m_output.at(start)) & 0xC0) == 0x80) {
        ++start;
    }
    m_output.remove(0, start);
}

// Only forget the path once it is gone: a survivor stays in `m_path` so the
// destructor makes another attempt, and `scriptLeftBehind` tells the window
// there is an executable it should name. A path that is not the current run's
// is only deleted, never kept.
void ScriptProcess::removeRunScript(const QString &path) {
    if (m_path != path) {
        QString ignored;
        removeScriptFile(path, ignored);
        return;
    }
    QString left;
    if (removeScriptFile(path, left)) m_path.clear();
    else m_path = left;
}

bool ScriptProcess::prepare(const QString &script, QString *errorText) {
    if (m_proc) return false;
    QTemporaryFile tmp(QDir::temp().filePath(QStringLiteral("appattic-XXXXXX.sh")));
    tmp.setAutoRemove(false);
    if (!tmp.open()) {
        if (errorText) *errorText = QStringLiteral("Could not write the script to run.");
        return false;
    }
    tmp.write(script.toUtf8());
    tmp.close();
    QFile::setPermissions(tmp.fileName(), QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);

    m_path = tmp.fileName();
    m_output.clear();
    m_stopped = false;
    m_reported = false;

    auto *proc = new QProcess(this);
    m_proc = proc;
    isolateScriptProcessGroup(proc);
    proc->setProcessChannelMode(QProcess::MergedChannels);
    proc->setStandardInputFile(QProcess::nullDevice());
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("DEBIAN_FRONTEND"), QStringLiteral("noninteractive"));
    env.insert(QStringLiteral("APT_LISTCHANGES_FRONTEND"), QStringLiteral("none"));
    proc->setProcessEnvironment(env);

    connect(proc, &QProcess::readyRead, this, [this, proc] { appendOutput(proc->readAll()); });
    connect(proc, &QProcess::finished, this, [this, proc, path = tmp.fileName()](int code) {
        appendOutput(proc->readAll());
        if (m_reported) return;
        m_reported = true;
        removeRunScript(path);
        m_timer->stop();
        const bool stopped = m_stopped;
        m_stopped = false;
        m_proc = nullptr;
        // Queued first: the handler owns this object and deletes it, which takes
        // `proc` with it.
        proc->deleteLater();
        emit finished(code, stopped, m_output);
    });
    connect(proc, &QProcess::errorOccurred, this, [this, proc, path = tmp.fileName()](QProcess::ProcessError err) {
        if (err != QProcess::FailedToStart) return;
        if (m_reported) return;
        m_reported = true;
        m_timer->stop();
        m_stopped = false;
        removeRunScript(path);
        m_proc = nullptr;
        proc->deleteLater();
        emit failed();
    });
    return true;
}

void ScriptProcess::start() {
    if (!m_proc) return;
    /* The deadline counts the run, not the gap between preparing it and
       starting it. `prepare` and `start` are separate so a caller can connect
       to `finished` and `failed` before the process exists, and that gap is
       caller code: it builds the busy chrome, arms the confirm blockers, and
       connects the handlers, so a caller that took a moment in between spent
       that moment of the script's ten minutes already. Starting the timer here
       also stops a prepared script that is never started from being torn down
       by a deadline that fired against no process. */
    m_timer->start(m_timeoutMs);
    m_proc->start(QStringLiteral("/bin/sh"), {m_path});
}

void ScriptProcess::stop() {
    QProcess *proc = m_proc;
    if (!proc || m_reported) return;
    m_stopped = true;
    signalScriptGroup(proc, SIGTERM);
    if (proc->waitForFinished(kScriptStopGraceMs)) return;
    signalScriptGroup(proc, SIGKILL);
    if (proc->waitForFinished(kScriptStopGraceMs)) return;
    /* SIGKILL cannot be caught, but a script blocked in uninterruptible sleep
       on a hung mount does not reach a zombie for it, so `waitForFinished` can
       still be false here with the group already signalled. Nothing will
       report the run: the window keeps `m_scanning` set and every action
       disabled until the process is killed from outside the window, and the
       script's temp file stays in the temp directory for as long. Report it as
       the stopped run it is, and leave the process and the file to this object:
       the destructor signals the group again and reaps what is left. */
    m_reported = true;
    emit finished(-1, true, m_output);
}
