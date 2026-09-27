#include "scriptproc.h"

#include <QDir>
#include <QFile>
#include <QProcess>
#include <QProcessEnvironment>
#include <QTemporaryFile>
#include <QTimer>

#include <csignal>
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

ScriptProcess::ScriptProcess(QObject *parent) : QObject(parent) {}

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
    // directory.
    if (!m_path.isEmpty()) {
        QFile::remove(m_path);
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

    auto *proc = new QProcess(this);
    m_proc = proc;
    isolateScriptProcessGroup(proc);
    proc->setProcessChannelMode(QProcess::MergedChannels);
    proc->setStandardInputFile(QProcess::nullDevice());
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("DEBIAN_FRONTEND"), QStringLiteral("noninteractive"));
    env.insert(QStringLiteral("APT_LISTCHANGES_FRONTEND"), QStringLiteral("none"));
    proc->setProcessEnvironment(env);

    m_timer = new QTimer(this);
    m_timer->setSingleShot(true);
    connect(m_timer, &QTimer::timeout, this, &ScriptProcess::stop);
    m_timer->start(kScriptTimeoutMs);

    connect(proc, &QProcess::readyRead, this, [this, proc] { appendOutput(proc->readAll()); });
    connect(proc, &QProcess::finished, this, [this, proc, path = tmp.fileName()](int code) {
        appendOutput(proc->readAll());
        if (m_path == path) m_path.clear();
        QFile::remove(path);
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
        m_timer->stop();
        m_stopped = false;
        if (m_path == path) m_path.clear();
        QFile::remove(path);
        m_proc = nullptr;
        proc->deleteLater();
        emit failed();
    });
    return true;
}

void ScriptProcess::start() {
    if (m_proc) m_proc->start(QStringLiteral("/bin/sh"), {m_path});
}

void ScriptProcess::stop() {
    QProcess *proc = m_proc;
    if (!proc) return;
    m_stopped = true;
    signalScriptGroup(proc, SIGTERM);
    if (proc->waitForFinished(kScriptStopGraceMs)) return;
    signalScriptGroup(proc, SIGKILL);
    proc->waitForFinished(kScriptStopGraceMs);
}
