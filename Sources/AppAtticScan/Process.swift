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
/// Assembled once: it costs a `homeDirectoryForCurrentUser` lookup, a
/// full `environment` copy, a PATH split and a readdir of every installed nvm
/// version, and `runCommand` calls `whichCommand` once per subprocess it
/// spawns (a scan runs hundreds). Only the directory list is cached, never a
/// name-to-path result, so a tool installed while the app runs is still found.
private let whichDirectoriesLock = NSLock()
nonisolated(unsafe) private var cachedWhichDirectories: [String]? = nil

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
    if let vers = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
        // Sorted: `contentsOfDirectory` returns readdir order, so an unsorted
        // list searches the node versions in a different order per process and
        // two installs of the same tool resolve to whichever came first.
        for v in vers.sorted() where !v.hasPrefix(".") {
            extras.append(nvmRoot + "/" + v + "/bin")
        }
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
    guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), size > 0 else { return "" }
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    do {
        try handle.seek(toOffset: start)
        guard let data = try handle.read(upToCount: maxBytes), !data.isEmpty else { return "" }
        return String(decoding: trimPartialLeadingUTF8(Array(data)), as: UTF8.self)
    } catch {
        return ""
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

/// SIGTERM, then SIGKILL if the process is still there a second later.
/// Returns true when it left on the first signal. `exited` is the semaphore
/// `runAndWait` and `runCommand` signalled the process's `terminationHandler`
/// with.
private func stopProcess(_ process: Process, exited: DispatchSemaphore) -> Bool {
    process.terminate()
    if exited.wait(timeout: .now() + processStopGrace) == .success { return true }
    kill(process.processIdentifier, SIGKILL)
    _ = exited.wait(timeout: .now() + processStopGrace)
    return false
}

/// Run `process` and wait for it, escalating to SIGKILL if it ignores SIGTERM
/// for a second. Returns true when it exited on its own within `timeout`,
/// false when the deadline passed and the process was killed. The exit status
/// is left on the process either way, so a timed-out run still has to be
/// reported as the failure it is: commands before the deadline may already
/// have run.
@discardableResult
public func runAndWait(_ process: Process, timeout: TimeInterval) throws -> Bool {
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    if exited.wait(timeout: .now() + timeout) == .success { return true }
    return stopProcess(process, exited: exited)
}

/// Runs `cmd` without a shell and returns (status, stdout, stderr). Status 127
/// with empty stdout means the command produced no usable result: empty argv,
/// executable not found, a timeout that killed the process, or output past
/// `commandOutputLimit`. A timeout discards the real status and stderr, so a
/// caller cannot tell a missing binary from a hang and must report the tool as
/// unavailable either way.
public func runCommand(_ cmd: [String], timeout: TimeInterval = 60) -> (Int32, String, String) {
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
    let collected = CommandPipes()
    let group = DispatchGroup()
    // Dedicated threads: pmap workers already occupy the GCD pool. Queueing
    // pipe reads on that pool deadlocks (workers wait for readers, readers wait
    // for threads).
    group.enter()
    Thread.detachNewThread {
        collected.out = collected.drain(outPipe.fileHandleForReading)
        group.leave()
    }
    group.enter()
    Thread.detachNewThread {
        collected.err = collected.drain(errPipe.fileHandleForReading)
        group.leave()
    }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        collected.closeDrainWindow()
        group.wait()
        return (127, "", error.localizedDescription)
    }
    try? outPipe.fileHandleForWriting.close()
    try? errPipe.fileHandleForWriting.close()
    // Block on the exit notification instead of polling `isRunning`: the old
    // 50 ms sleep charged a full tick to every subprocess, so a scan that runs
    // dozens of `which`/`du`/package queries paid that dead time per call
    // whether the command took 1 ms or the full timeout.
    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        _ = stopProcess(process, exited: exited)
    }
    process.waitUntilExit()
    // The exit above ends the direct child, but a descendant holding the write
    // end leaves the readers with no EOF. Handing them a deadline is what makes
    // them finish: a detached reader blocked on `read` outlives the call, and a
    // scan that runs dozens of commands leaks two threads and two descriptors
    // per such command.
    collected.closeDrainWindow()
    group.wait()
    if timedOut {
        return (127, "", "timeout")
    }
    if collected.overflowed {
        return (127, "", "output limit exceeded: \(commandOutputLimit) bytes")
    }
    let out = decodeUTF8(collected.out)
    let err = decodeUTF8(collected.err)
    return (process.terminationStatus, out, err)
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
    try writeOwnerOnlyFile(Data(script.utf8), to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    try writeOwnerOnlyFile(Data(), to: errURL)
    defer { try? FileManager.default.removeItem(at: errURL) }
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
    let finished = try runAndWait(process, timeout: timeout)
    try? errHandle.synchronize()
    try? errHandle.close()
    openErrHandle = nil
    var status = process.terminationStatus
    var stderr = readCommandOutputTail(from: errURL)
    if !finished {
        // A script blocked on a stale package lock, an unreachable mirror, or
        // a prompt nothing can answer would otherwise wait forever. What it
        // already did is not undone, so the message says so.
        if status == 0 { status = scriptStoppedStatus }
        let note = scriptStoppedNote(timeout: timeout)
        stderr = stderr.isEmpty ? note : stderr + "\n" + note
    }
    return ScriptRun(status: status, stderr: stderr, finished: finished)
}

private final class CommandPipes: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()
    private var drainDeadline = TimeInterval.greatestFiniteMagnitude
    private var _overflowed = false
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
        drainDeadline = monotonicSeconds() + commandPipeDrainGrace
        lock.unlock()
    }

    private func drainTimeLeft() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return drainDeadline - monotonicSeconds()
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
