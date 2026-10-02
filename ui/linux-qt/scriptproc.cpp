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

/// Whether a run crosses the Flatpak sandbox boundary. `FLATPAK_ID` is what
/// Flatpak sets, and what `core/host/hostexec.c` and `ui/linux-qt/corehost.cpp`
/// already read, so all three agree on one signal rather than three spellings
/// of "sandboxed". Taken as a parameter so the helper tests can drive both
/// sides without a Flatpak; `start` passes the environment's own value.
///
/// Trimmed before it is read, because the rest of the tree treats a blank
/// `FLATPAK_ID` as unset: `core/host/hostexec.c` has an `env_set` helper for
/// exactly that, and `corehost.cpp` uses `qEnvironmentVariableIsEmpty`. A
/// whitespace-only value is a variable somebody exported by accident, and
/// reading it as sandboxed would send a host run through a `flatpak-spawn` that
/// is not installed.
bool scriptRunsOnHost(const QString &flatpakId) {
    return !flatpakId.trimmed().isEmpty();
}

/// The program and arguments one run spawns, and whether the script is handed
/// over on stdin instead of by path. Under a Flatpak the run is
/// `flatpak-spawn --host -- /bin/sh` with the script on stdin, because the
/// manifest grants `--filesystem=host:ro` and no host write, and because the
/// script is in the sandbox temp directory the host cannot see: passing the
/// path would have the host shell report "No such file or directory" for a
/// cleanup the user confirmed, which is the silent failure this shape exists
/// to prevent. On a host it is `sh <path>`, unchanged.
void scriptCommand(const QString &path, const QString &flatpakId, QString *program,
                   QStringList *args, bool *scriptOnStdin) {
    if (scriptRunsOnHost(flatpakId)) {
        *program = QStringLiteral("flatpak-spawn");
        *args = {QStringLiteral("--host"), QStringLiteral("--"),
                 QStringLiteral("/bin/sh")};
        if (scriptOnStdin) *scriptOnStdin = true;
        return;
    }
    *program = QStringLiteral("/bin/sh");
    *args = {path};
    if (scriptOnStdin) *scriptOnStdin = false;
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
    int lead = 0;
    while (lead < m_output.size()
           && (static_cast<unsigned char>(m_output.at(lead)) & 0xC0) == 0x80) {
        ++lead;
    }
    m_output.remove(0, lead);
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
    /* Owner-only mode before the body, not after it. QTemporaryFile creates at
       the umask default, which is 0644 under the usual 022, and the temp
       directory is shared: for as long as the write below is in flight every
       local account can read the `rm -rf` list the user just confirmed, and a
       reader that gets in before the chmod can rewrite it. The file is empty at
       this point, so there is nothing to disclose and a mode that cannot be set
       means the run is refused rather than run from a file anyone else can
       read. Same order as `writeDurableFile` in settings.cpp. */
    if (!QFile::setPermissions(tmp.fileName(), QFile::ReadOwner | QFile::WriteOwner)) {
        tmp.close();
        QFile::remove(tmp.fileName());
        if (errorText) *errorText = QStringLiteral("Could not make the script private to run it.");
        return false;
    }
    const QByteArray body = script.toUtf8();
    if (tmp.write(body) != body.size()) {
        tmp.close();
        QFile::remove(tmp.fileName());
        if (errorText) *errorText = QStringLiteral("Could not write the script to run.");
        return false;
    }
    tmp.close();
    /* The execute bit comes after the write, because the file does not have to
       be runnable while it holds the body. */
    QFile::setPermissions(tmp.fileName(), QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);

    m_path = tmp.fileName();
    m_output.clear();
    m_stopped = false;
    m_reported = false;

    auto *proc = new QProcess(this);
    m_proc = proc;
    isolateScriptProcessGroup(proc);
    proc->setProcessChannelMode(QProcess::MergedChannels);
    /* stdin is set in `start`, where the program is known: a host run has no
       input, and a sandboxed run hands the script itself over the same pipe
       (see `start`). Setting it here would make that write go to /dev/null. */
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
    /* Sandboxed, the script runs on the host. Two things force it out of the
       sandbox rather than running `/bin/sh` here: the Flatpak grants
       `--filesystem=host:ro` and no host write, so `rm`, `apt-get purge` and
       `flatpak uninstall` from inside would fail on every packaged path they
       were confirmed to touch; and the script is written to the sandbox temp
       directory, which the host cannot see, so its path is not a usable
       argument. The manifest's grant is honest only because of this:
       `core/host/hostexec.c` leaves the sandbox the same way for its
       allowlisted queries. `scriptCommand` is where that shape is spelled, and
       the helper tests pin both sides of it. */
    QString program;
    QStringList args;
    bool scriptOnStdin = false;
    scriptCommand(m_path, qEnvironmentVariable("FLATPAK_ID"), &program, &args,
                  &scriptOnStdin);
    QByteArray hostScript;
    if (scriptOnStdin) {
        QFile script(m_path);
        /* Read the script before the child exists. A host shell handed nothing
           on stdin exits 0 having done nothing, which reads to the window as a
           clean cleanup that removed nothing, so a script that cannot be read
           is refused here rather than started. */
        if (!script.open(QIODevice::ReadOnly)) {
            /* The same four steps the `FailedToStart` handler in `prepare`
               takes: `failed` means the run is over, so the deadline is
               disarmed, the run is marked reported so a later `finished`
               cannot report it twice, the script goes while this object still
               knows its path, and the `QProcess` is let go. Only the timer and
               the signal were here, so `m_proc` survived a `failed` and
               `running()` answered true for a process that never started
               while every later `prepare` refused on the same handle. */
            m_timer->stop();
            m_reported = true;
            removeRunScript(m_path);
            QProcess *proc = m_proc;
            m_proc = nullptr;
            proc->deleteLater();
            emit failed();
            return;
        }
        hostScript = script.readAll();
        /* QProcess buffers what is written before the child exists and flushes
           it at start, so the whole script goes in one write, and the channel
           is closed in `started`, where the child is known to be reading. */
        connect(m_proc, &QProcess::started, this, [proc = m_proc]() {
            proc->closeWriteChannel();
        });
    } else {
        /* No stdin for a host run: the script must not wait on a terminal, and
           nothing it runs reads input. Set here rather than in `prepare`, where
           it would have made the sandboxed `write` a write to /dev/null. */
        m_proc->setStandardInputFile(QProcess::nullDevice());
    }
    m_proc->start(program, args);
    if (scriptOnStdin) m_proc->write(hostScript);
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
