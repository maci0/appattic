import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// First executable named `name`, or nil. A name containing `/` is used as a
/// path. Otherwise the per-user toolchain directories below are searched
/// *before* `PATH`, so a `brew` in `~/.local/bin` wins over an earlier `PATH`
/// entry on purpose: those directories are where this project's own overlays
/// put a tool, and a stale copy in `PATH` would scan the wrong install.
public func whichCommand(_ name: String) -> String? {
    if name.isEmpty { return nil }
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    for dir in whichSearchDirectories() {
        let candidate = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// The directories `whichCommand` walks, de-duplicated, first-wins.
///
/// Assembled once per scan: it costs a `homeDirectoryForCurrentUser` lookup, a
/// full `environment` copy, a PATH split and a readdir of every installed nvm
/// version, and `runCommand` calls `whichCommand` once per subprocess it
/// spawns (a scan runs hundreds). Only the directory list is cached, never a
/// name-to-path result, so a tool installed while the app runs is still found
/// as long as the list is rebuilt.
///
/// The list is its own key: nothing in it, and nothing a lookup of a name
/// inside it, can tell the process that a directory was added, that PATH
/// changed, or that another nvm version appeared. A long lived UI that kept
/// the first list for its whole life would resolve `brew`, `mas` or a nvm tool
/// against the directories the machine had at launch, and the scan cache
/// fingerprint is built from those same lookups, so a tool installed since
/// would leave the fingerprint unchanged and the stale snapshot serving.
/// `performScan` calls `resetWhichSearchDirectories()` before it collects, and
/// so does `scanFingerprint` before it stamps, so the list is rebuilt at both
/// points where a wrong answer about the machine is a wrong cache decision.
private let whichDirectoriesLock = NSLock()
nonisolated(unsafe) private var cachedWhichDirectories: [String]? = nil

func resetWhichSearchDirectories() {
    whichDirectoriesLock.lock()
    cachedWhichDirectories = nil
    whichDirectoriesLock.unlock()
}

private func whichSearchDirectories() -> [String] {
    whichDirectoriesLock.lock()
    defer { whichDirectoriesLock.unlock() }
    if let cached = cachedWhichDirectories { return cached }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var extras = [
        home + "/.local/bin",
        home + "/bin",
        home + "/.bun/bin",
        home + "/.deno/bin",
        home + "/.volta/bin",
        home + "/.yarn/bin",
        home + "/.cargo/bin",
        home + "/.fnm/aliases/default/bin",
        home + "/.local/share/pnpm",
        home + "/.npm-global/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    let nvmRoot = home + "/.nvm/versions/node"
    // `directoryEntryNames` sorts, so the node versions are searched in a
    // stable order and two installs of the same tool resolve to the same one
    // on every process.
    for v in directoryEntryNames(nvmRoot) {
        extras.append(nvmRoot + "/" + v + "/bin")
    }
    let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.isEmpty }
    var seen = Set<String>()
    let resolved = (extras + pathDirs).filter { !$0.isEmpty && seen.insert($0).inserted }
    cachedWhichDirectories = resolved
    return resolved
}

/// Cached process username: environment copy + trims + folds per call cost
/// ~2 µs, and `classify` calls this per entry. The account name cannot change
/// mid-scan.
private let cachedUsernameLock = NSLock()
nonisolated(unsafe) private var cachedUsername: String? = nil

func currentUsername() -> String {
    cachedUsernameLock.lock()
    defer { cachedUsernameLock.unlock() }
    if let cached = cachedUsername { return cached }
    let resolved: String = {
        let env = ProcessInfo.processInfo.environment
        let raw = (env["USER"] ?? env["LOGNAME"] ?? "").trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty { return posixLowercased(raw) }
        #if os(macOS)
        let name = NSUserName().trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return posixLowercased(name) }
        #endif
        return posixLowercased(ProcessInfo.processInfo.userName)
    }()
    cachedUsername = resolved
    return resolved
}

/// Process environment with `cleanupPathDirectories()` prepended to PATH,
/// de-duplicated and first-wins.
public func augmentedProcessEnvironment(
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var out = env
    var seen = Set<String>()
    var parts: [String] = []
    for dir in cleanupPathDirectories() + (env["PATH"] ?? "").split(separator: ":").map(String.init) {
        if !dir.isEmpty, seen.insert(dir).inserted {
            parts.append(dir)
        }
    }
    out["PATH"] = parts.joined(separator: ":")
    return out
}

/// How long the pipe readers may keep draining after the command itself is
/// gone. A descendant that inherited the write end (a backgrounded grandchild,
/// a helper `brew` forgot to reap) holds the pipe open, so the reader has no
/// EOF to wait for and is given a deadline instead. A pipe still drains at once
/// once its last writer closed, so a normal command never spends this.
public let commandPipeDrainGrace: TimeInterval = 2

/// How often a reader wakes to re-read its deadline, which the calling thread
/// opens once the process has exited.
private let commandPipePollSliceMs: Int = 100

/// How often the wait for a spawned command re-checks the direct child after
/// the `terminationHandler` has not fired. `waitpid` is asked first (see
/// `waitForDirectChild`), so this bounds how late a handler that never arrives
/// is noticed, not how long a command that has already exited is waited on.
private let childExitPollInterval: TimeInterval = 0.1

/// How long the timeout path keeps reaping a stopped child before giving it up
/// and returning. Bounded on purpose: `stopProcess` has already signalled the
/// process group twice, and a descendant that called `setsid()` sits outside
/// that group, so the exit notification can still be pending for a process
/// nobody is waiting on. The status is discarded on this path either way.
private let stoppedChildReapTimeout: TimeInterval = 1.0

/// How much of a redirected command's output a report keeps. A package
/// transaction writes a line per file it touches and can run for minutes, and
/// the report shows a few hundred characters of the end, so the rest is read
/// only to be thrown away.
public let commandOutputTailBytes: Int = 64 * 1024

/// The last `maxBytes` of the file at `url`, or `""` when it cannot be read.
///
/// Reads the tail rather than the whole file: the caller runs the script first
/// and reads the result after, so a transaction that printed megabytes would
/// otherwise cost that much memory in the UI that is still running.
public func readCommandOutputTail(
    from url: URL,
    maxBytes: Int = commandOutputTailBytes
) -> String {
    readCommandOutputTailIfPresent(from: url, maxBytes: maxBytes) ?? ""
}

/// The same tail, or nil when the file could not be read at all. A file that is
/// there and empty is not a failure and reads as `""`.
///
/// The two are different to a caller reporting a failed run: a script that
/// wrote nothing to stderr and a stderr that could not be read both arrive as
/// an empty string, and the first is a real answer while the second leaves the
/// operator with a nonzero exit and no reason for it.
private func readCommandOutputTailIfPresent(
    from url: URL,
    maxBytes: Int
) -> String? {
    guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    if size == 0 { return "" }
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    do {
        try handle.seek(toOffset: start)
        guard let data = try handle.read(upToCount: maxBytes) else { return nil }
        return String(decoding: trimPartialLeadingUTF8(Array(data)), as: UTF8.self)
    } catch {
        return nil
    }
}

/// Drops the leading bytes of a cut UTF-8 sequence, so a tail that starts
/// mid-character does not decode to a replacement character at the front.
private func trimPartialLeadingUTF8(_ bytes: [UInt8]) -> [UInt8] {
    var start = 0
    while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
    return start == 0 ? bytes : Array(bytes[start...])
}

/// Bytes a single stream of one command may contribute before the result is
/// declared unusable. Every query this app runs prints a listing, not a log:
/// the largest of them (`brew outdated --json`, `dnf list --upgrades`, `pip list
/// --format=json`) is orders of magnitude below this, and a command that
/// exceeds it is misbehaving or stuck in a loop. Without a cap the whole
/// stream is held in memory, and the scan's cost is whatever the command
/// decides to print. The C host makes the same call against the same kind of
/// output (`appattic_host_exec` takes the cap from its caller and stops there).
public let commandOutputLimit: Int = 8 * 1024 * 1024

/// How long a generated cleanup, update, or mark-manual script may run before
/// it is terminated. These scripts are the only commands here that change the
/// system, and a package manager is entitled to take minutes, so the bound is
/// generous; the point is that a script blocked on a stale dpkg lock, an
/// unreachable mirror, or a prompt that can never be answered leaves the UI
/// with its buttons disabled forever. Query commands use the 60 s default of
/// `runCommand` instead. The scripts are not rolled back, so a stop mid-run is
/// reported as partial work, never as a clean failure.
public let scriptRunTimeout: TimeInterval = 600

/// How long a terminated process gets to exit before it is killed. `sh` and
/// the package managers below it both handle SIGTERM, so this is only reached
/// by a process that is stuck rather than slow.
private let processStopGrace: TimeInterval = 1

/// Signal `process` and everything it started.
///
/// `Process` starts the child in this process's own group, so `terminate` and
/// `kill` reach `/bin/sh` and nothing below it: the apt, pacman, or flatpak
/// process `sh` is waiting on is a separate process and survives both. A
/// stopped script would then report a clean stop while that process kept
/// holding the package-manager lock and kept removing packages behind the
/// window. The host makes the same pair for every subprocess it spawns
/// (`core/host/hostexec.c`).
///
/// The group is only there if `isolateProcessGroup` won its race, so the
/// group signal falls back to the direct child. A child that is not a group
/// leader belongs to its parent's group, and no group carries the child's own
/// id, so the group signal fails with `ESRCH` rather than reaching this
/// process's group.
private func signalProcessGroup(_ process: Process, _ sig: Int32) {
    let pid = process.processIdentifier
    if pid > 0, kill(-pid, sig) == 0 { return }
    if sig == SIGKILL {
        kill(pid, SIGKILL)
    } else {
        process.terminate()
    }
}

/// Give `process` its own process group, so a stop can reach the commands it
/// runs. `Process` has no hook for the child to do this before `exec`, so the
/// call races the child: it loses once the child has exec'd, and the stop
/// falls back to the direct child, which is what happened before.
private func isolateProcessGroup(_ process: Process) {
    let pid = process.processIdentifier
    if pid > 0 { _ = setpgid(pid, pid) }
}

/// SIGTERM to the whole group, then SIGKILL if any of it is still there a
/// second later. `exited` is the semaphore the caller's `terminationHandler`
/// signalled the direct child's exit with, which is the only way to tell that
/// a group whose `sh` died took its package manager with it or left it running.
private func stopProcess(_ process: Process, exited: DispatchSemaphore) {
    signalProcessGroup(process, SIGTERM)
    if exited.wait(timeout: .now() + processStopGrace) == .success { return }
    signalProcessGroup(process, SIGKILL)
    _ = exited.wait(timeout: .now() + processStopGrace)
}

/// Run `process` and wait for it, escalating to SIGKILL if it ignores SIGTERM
/// for a second. Returns true when it exited on its own within `timeout`,
/// false when the deadline passed and the process was stopped. The exit status
/// is left on the process either way, so a timed-out run still has to be
/// reported as the failure it is: commands before the deadline may already
/// have run.
///
/// A deadline stop is `false` however quickly the stop landed. A `sh` that
/// forwards SIGTERM to the command below it, or a package manager that exits
/// on it, used to answer the wait inside the grace period and read as a script
/// that finished; it was stopped, and the lines before the stop ran.
///
/// `runAndWaitForExit` is the same wait with the exit status it reaps handed
/// back: a caller that reads `terminationStatus` has to use that one, because
/// the wait can be the one that reaps the child itself.
@discardableResult
public func runAndWait(_ process: Process, timeout: TimeInterval) throws -> Bool {
    try runAndWaitForExit(process, timeout: timeout).timedOut == false
}

/// `runAndWait` with the exit status the wait reaped.
func runAndWaitForExit(_ process: Process, timeout: TimeInterval) throws -> ChildExit {
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    isolateProcessGroup(process)
    return waitForDirectChild(process, exited: exited, timeout: timeout)
}

/// How a spawned command ended.
struct ChildExit {
    /// True when the deadline passed and the process was stopped.
    var timedOut: Bool
    /// The exit status this wait reaped itself, or nil when Foundation reaped
    /// the child and `Process.terminationStatus` is the one to read.
    var reapedStatus: Int32?

    /// The status to report, from whichever of the two has it.
    func status(from process: Process) -> Int32 {
        reapedStatus ?? process.terminationStatus
    }
}

/// What a zero-timeout `waitpid` on a spawned command's direct child found.
private enum DirectChildState {
    /// Still running.
    case running
    /// Gone, and this call is the one that reaped it: the raw `wait` status
    /// comes back with it.
    case reaped(Int32)
    /// Gone, and Foundation reaped it: `Process.terminationStatus` is the
    /// status to read, and `waitUntilExit` returns without waiting for the
    /// child's own descendants.
    case reapedElsewhere
}

/// `waitpid(pid, WNOHANG)`, the one signal for "the direct child exited" that
/// does not wait out the child's own descendants.
///
/// `Process.terminationHandler` is not that signal on Linux: libdispatch
/// reports the child as exited only once everything it spawned is gone too, so
/// `sh -c "helper &"` signals the handler when `helper` exits — seconds later,
/// or never. A command that has already exited is then cut off at its own
/// timeout and reported as a timeout it never had, with its real status
/// thrown away. The direct child is reapable the moment it exits, so the wait
/// below asks `waitpid` as well.
private func directChildState(_ pid: pid_t) -> DirectChildState {
    guard pid > 0 else { return .running }
    var status: Int32 = 0
    let reaped = waitpid(pid, &status, WNOHANG)
    if reaped == pid { return .reaped(status) }
    if reaped == 0 { return .running }
    // ECHILD: there is no such child left to wait for, so something else has it.
    return errno == ECHILD ? .reapedElsewhere : .running
}

/// The exit status a reaped child reports, decoded the way
/// `Process.terminationStatus` spells it. The `WIFEXITED` family is not
/// importable into Swift, so the raw `wait` status is read by hand: the low
/// seven bits are the signal that ended the child (0 for a normal exit, 0x7f
/// for a stop), and the byte above them is its exit code. A child killed by a
/// signal therefore reports the signal number, which is what Foundation
/// reports for one too.
private func exitStatus(fromWaitStatus status: Int32) -> Int32 {
    let signal = status & 0x7f
    if signal == 0 { return (status >> 8) & 0xff }
    if signal == 0x7f { return status }
    return signal
}

/// Wait for `process` to exit, for `exited` to be signalled, or for `timeout`
/// to pass.
///
/// `waitpid` is asked before the semaphore, not after: the semaphore is a
/// deadline-bounded wait, so putting it first charged every command up to a
/// whole `childExitPollInterval` of dead time on the platform where
/// `terminationHandler` is late. `waitpid(WNOHANG)` costs one syscall and
/// answers immediately, and the two signals race for the same child anyway
/// (whichever wins, the loser sees `.reapedElsewhere` or `.reaped`), so the
/// cheap question goes first.
private func waitForDirectChild(
    _ process: Process,
    exited: DispatchSemaphore,
    timeout: TimeInterval
) -> ChildExit {
    let pid = process.processIdentifier
    let deadline = monotonicSeconds() + timeout
    // The injected clock is the pipe drain window's, and a stepped one must not
    // decide how long a command may run: the deadline is the host's own clock.
    while true {
        switch directChildState(pid) {
        case .reaped(let status):
            // Foundation's handler is still pending and never will report this
            // child, so `waitUntilExit` would block here until the descendants
            // it left behind are gone. The status came with the reap.
            return ChildExit(timedOut: false, reapedStatus: exitStatus(fromWaitStatus: status))
        case .reapedElsewhere:
            process.waitUntilExit()
            return ChildExit(timedOut: false, reapedStatus: nil)
        case .running:
            break
        }
        if monotonicSeconds() >= deadline {
            stopProcess(process, exited: exited)
            return ChildExit(timedOut: true, reapedStatus: reapStoppedChild(pid, exited))
        }
        if exited.wait(timeout: .now() + childExitPollInterval) == .success {
            process.waitUntilExit()
            return ChildExit(timedOut: false, reapedStatus: nil)
        }
    }
}

/// Reap the direct child of a command that was just stopped, or give up.
///
/// Not `waitUntilExit`: that returns only once everything the child spawned is
/// gone, and `stopProcess` has just come back from a semaphore that never
/// fired, which says the exit notification is still pending. The direct child
/// is reapable on its own, so poll that, and give up rather than block the
/// caller for good.
private func reapStoppedChild(_ pid: pid_t, _ exited: DispatchSemaphore) -> Int32? {
    let deadline = monotonicSeconds() + stoppedChildReapTimeout
    while true {
        switch directChildState(pid) {
        case .reaped(let status):
            return exitStatus(fromWaitStatus: status)
        case .reapedElsewhere:
            return nil
        case .running:
            break
        }
        if monotonicSeconds() >= deadline { return nil }
        _ = exited.wait(timeout: .now() + childExitPollInterval)
    }
}

/// Runs `cmd` without a shell and returns (status, stdout, stderr). Status 127
/// with empty stdout means the command produced no usable result: empty argv,
/// executable not found, a timeout that killed the process, or output past
/// `commandOutputLimit`. A timeout discards the real status and stderr, so a
/// caller cannot tell a missing binary from a hang and must report the tool as
/// unavailable either way.
public func runCommand(_ cmd: [String], timeout: TimeInterval = 60) -> (Int32, String, String) {
    runCommand(cmd, timeout: timeout, clock: monotonicSeconds)
}

/// `runCommand` with the elapsed-time source of the pipe drain window taken
/// from `clock`. The window is the only deadline here that a replayed run
/// could not otherwise step, and it decides whether stdout is whole or cut at
/// a partial read: a scan that inherits a loaded host's uptime reports a
/// truncated listing with the command's own exit status, which no caller
/// treats as a failure.
func runCommand(_ cmd: [String], timeout: TimeInterval, clock: @escaping MonotonicFn) -> (Int32, String, String) {
    guard let exe = cmd.first else { return (127, "", "empty command") }
    let resolved: String
    if exe.hasPrefix("/") {
        resolved = exe
    } else if let found = whichCommand(exe) {
        resolved = found
    } else {
        return (127, "", "not found: \(exe)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: resolved)
    process.arguments = Array(cmd.dropFirst())
    var env = ProcessInfo.processInfo.environment
    if URL(fileURLWithPath: resolved).lastPathComponent == "brew" {
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    }
    process.environment = env
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    process.standardInput = FileHandle.nullDevice
    let outRead = outPipe.fileHandleForReading
    let errRead = errPipe.fileHandleForReading
    let collected = CommandPipes(clock: clock)
    let group = DispatchGroup()
    // Dedicated threads: pmap workers already occupy the GCD pool. Queueing
    // pipe reads on that pool deadlocks (workers wait for readers, readers wait
    // for threads).
    //
    startPipeReader(in: group) {
        collected.out = collected.drain(outRead)
    }
    startPipeReader(in: group) {
        collected.err = collected.drain(errRead)
    }
    // The read ends are this function's, and both readers are joined before
    // either close, so a run cannot hand a live descriptor to the next one.
    // The write ends are closed below, once the child owns its copies.
    func closeReadEnds() {
        try? outRead.close()
        try? errRead.close()
    }
    func closeWriteEnds() {
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
    }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        closeWriteEnds()
        collected.closeDrainWindow()
        group.wait()
        closeReadEnds()
        return (127, "", error.localizedDescription)
    }
    isolateProcessGroup(process)
    closeWriteEnds()
    // Block on the exit notification instead of polling `isRunning`: the old
    // 50 ms sleep charged a full tick to every subprocess, so a scan that runs
    // dozens of `which`/`du`/package queries paid that dead time per call
    // whether the command took 1 ms or the full timeout. The handler is not
    // enough on its own: see `waitForDirectChild` for the command that exits
    // and leaves a descendant holding the pipe.
    let exit = waitForDirectChild(process, exited: exited, timeout: timeout)
    let timedOut = exit.timedOut
    // The exit above ends the direct child, but a descendant holding the write
    // end leaves the readers with no EOF. Handing them a deadline is what makes
    // them finish: a detached reader blocked on `read` outlives the call, and a
    // scan that runs dozens of commands leaks two threads and two descriptors
    // per such command.
    collected.closeDrainWindow()
    group.wait()
    closeReadEnds()
    if timedOut {
        return (127, "", "timeout")
    }
    if collected.overflowed {
        return (127, "", "output limit exceeded: \(commandOutputLimit) bytes")
    }
    let out = decodeUTF8(collected.out)
    let err = decodeUTF8(collected.err)
    return (exit.status(from: process), out, err)
}

/// Runs one pipe reader on its own thread, joined by `group` on every path.
private func startPipeReader(in group: DispatchGroup, _ body: @escaping () -> Void) {
    group.enter()
    Thread.detachNewThread {
        body()
        group.leave()
    }
}

/// The status a stopped script reports, 124 being the shell's own "timed out".
public let scriptStoppedStatus: Int32 = 124

/// What a stopped script means for the operator. A generated script removes
/// files and uninstalls packages, so there is no rollback: the wording says
/// the run was cut short instead of letting a partial removal read as a clean
/// one. The bound defaults to `scriptRunTimeout`, the one every script runner
/// applies, so the number printed is the number that fired.
public func scriptStoppedMessage(timeout: TimeInterval = scriptRunTimeout) -> String {
    "the script was stopped after \(Int(timeout / 60)) minutes without finishing; "
        + "commands before the stop may have already run."
}

/// The same stop, as a line appended to the script's own stderr, where it
/// lands next to whatever `set -e` reported.
public func scriptStoppedNote(timeout: TimeInterval = scriptRunTimeout) -> String {
    "timed out after \(Int(timeout))s; commands before the timeout may have already run"
}

/// What a generated script run left behind: the exit status, the tail of its
/// stderr, and whether it finished before the deadline.
public struct ScriptRun: Sendable {
    public let status: Int32
    public let stderr: String
    public let finished: Bool
}

/// Runs a generated cleanup, update, or mark-manual script under `/bin/sh` and
/// waits up to `timeout` for it.
///
/// The script and its stderr go to temp files rather than pipes: under `set -e`
/// the first failing line is the only thing that says what went wrong, and it
/// has to arrive after the run, not interleaved with a UI that is still
/// scanning. A script that outruns `timeout` is stopped and reported as
/// `scriptStoppedStatus` with the reason appended to stderr, so the caller
/// never sees a killed process as an ordinary nonzero exit. `discardStdout`
/// sends the script's own output to the void, which is what a UI run wants:
/// the operator reads the progress already on screen, not a shell's
/// scrollback.
public func runGeneratedScript(
    _ script: String,
    discardStdout: Bool = false,
    timeout: TimeInterval = scriptRunTimeout
) throws -> ScriptRun {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("appattic-script-\(UUID().uuidString).sh")
    let errURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("appattic-script-\(UUID().uuidString).err")
    // Registered before either write, not after. A write that fails partway
    // leaves the temp name behind. With the removal armed first, that path
    // takes the temp file with it; a removal for a file the write never
    // created is a no-op.
    defer { try? FileManager.default.removeItem(at: url) }
    defer { try? FileManager.default.removeItem(at: errURL) }
    try writeOwnerOnlyFile(Data(script.utf8), to: url)
    try writeOwnerOnlyFile(Data(), to: errURL)
    let errHandle = try FileHandle(forWritingTo: errURL)
    // Closed before the file is read back, and the defer is the exit-path
    // close: closing a FileHandle twice is an exception Foundation does not
    // raise as a Swift error.
    var openErrHandle: FileHandle? = errHandle
    defer { try? openErrHandle?.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [url.path]
    process.environment = augmentedProcessEnvironment()
    if discardStdout {
        process.standardOutput = FileHandle.nullDevice
    }
    process.standardError = errHandle
    process.standardInput = FileHandle.nullDevice
    let exit = try runAndWaitForExit(process, timeout: timeout)
    let finished = exit.timedOut == false
    try? errHandle.synchronize()
    try? errHandle.close()
    openErrHandle = nil
    // From the wait, not from the process: the wait is what reaps the child
    // when Foundation's handler is late, and Foundation then has no status to
    // report at all.
    var status = exit.status(from: process)
    // The stderr tail is the only thing that says which line of `set -e`
    // stopped the script, so a read that failed is not an empty stderr: it is
    // a run whose reason is unknown, and the report says so rather than
    // printing a bare exit status.
    var stderr = readCommandOutputTailIfPresent(from: errURL, maxBytes: commandOutputTailBytes)
        ?? "the script's error output could not be read, so the reason for this run is unknown"
    if !finished {
        // A script blocked on a stale package lock, an unreachable mirror, or
        // a prompt nothing can answer would otherwise wait forever. What it
        // already did is not undone, so the message says so.
        //
        // The status a stop produced says how the process was killed, not what
        // went wrong: SIGTERM and SIGKILL arrive as 15 and 9, and which of the
        // two landed depends on how the script was feeling. The deadline is
        // the reason, and `scriptStoppedStatus` is the one that names it.
        status = scriptStoppedStatus
        let note = scriptStoppedNote(timeout: timeout)
        stderr = stderr.isEmpty ? note : stderr + "\n" + note
    }
    return ScriptRun(status: status, stderr: stderr, finished: finished)
}

private final class CommandPipes: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: MonotonicFn
    private var _out = Data()
    private var _err = Data()
    private var drainDeadline = TimeInterval.greatestFiniteMagnitude
    private var _overflowed = false

    init(clock: @escaping MonotonicFn = monotonicSeconds) {
        self.clock = clock
    }

    var out: Data {
        get { lock.lock(); defer { lock.unlock() }; return _out }
        set { lock.lock(); defer { lock.unlock() }; _out = newValue }
    }
    var err: Data {
        get { lock.lock(); defer { lock.unlock() }; return _err }
        set { lock.lock(); defer { lock.unlock() }; _err = newValue }
    }
    /// True once a stream passed `commandOutputLimit`. The result is then
    /// unusable: a prefix of a listing is not a listing, and no parser of a
    /// truncated stream is entitled to the answer.
    var overflowed: Bool {
        lock.lock(); defer { lock.unlock() }; return _overflowed
    }

    /// Opens the window a `drain` may spend past the command's own exit. Until
    /// it is called the reader waits for EOF: a command still writing must not
    /// be cut off at its timeout.
    func closeDrainWindow() {
        lock.lock()
        drainDeadline = clock() + commandPipeDrainGrace
        lock.unlock()
    }

    private func drainTimeLeft() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return drainDeadline - clock()
    }

    private func appendCapped(_ slice: ArraySlice<UInt8>, to data: inout Data) {
        let room = commandOutputLimit - data.count
        if room <= 0 {
            lock.lock()
            _overflowed = true
            lock.unlock()
            return
        }
        if slice.count > room {
            data.append(contentsOf: slice.prefix(room))
            lock.lock()
            _overflowed = true
            lock.unlock()
            return
        }
        data.append(contentsOf: slice)
    }

    /// Reads to EOF, or until the drain window closes, whichever comes first.
    /// `readDataToEndOfFile` cannot express the second case: it blocks on a
    /// descriptor a backgrounded grandchild still holds open. Reading past
    /// `commandOutputLimit` continues without buffering, because a reader that
    /// stops early blocks the writer and turns a runaway command into a hung
    /// one.
    func drain(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var data = Data()
        while true {
            let left = drainTimeLeft()
            if left <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            // Re-check the deadline in short slices: the window is opened from
            // the caller's thread after the process exits.
            let waitMs = Int32(min(left * 1000, Double(commandPipePollSliceMs)))
            let ready = poll(&pfd, 1, waitMs)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            appendCapped(buffer[0..<n], to: &data)
        }
        return data
    }
}
