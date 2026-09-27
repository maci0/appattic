import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public func whichCommand(_ name: String) -> String? {
    if name.isEmpty { return nil }
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
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
        for v in vers where !v.hasPrefix(".") {
            extras.append(nvmRoot + "/" + v + "/bin")
        }
    }
    let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.isEmpty }
    var seen = Set<String>()
    for dir in extras + pathDirs {
        if !seen.insert(dir).inserted { continue }
        let candidate = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
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
/// a helper `brew` forgot to reap) holds the pipe open, and `readDataToEndOfFile`
/// then blocks long past the exit. A pipe still drains at once once its last
/// writer closed, so a normal command never spends this.
public let commandPipeDrainGrace: TimeInterval = 2

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
        collected.out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    Thread.detachNewThread {
        collected.err = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
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
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
    }
    process.waitUntilExit()
    // Bounded, not unconditional: the exit above ends the direct child, but a
    // descendant holding the write end leaves the readers blocked. The timeout
    // is meant to bound the whole call, so waiting on them without a deadline
    // would turn a hung command into a hung scan.
    _ = group.wait(timeout: .now() + commandPipeDrainGrace)
    if timedOut {
        return (127, "", "timeout")
    }
    let out = decodeUTF8(collected.out)
    let err = decodeUTF8(collected.err)
    return (process.terminationStatus, out, err)
}

private final class CommandPipes: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()
    var out: Data {
        get { lock.lock(); defer { lock.unlock() }; return _out }
        set { lock.lock(); defer { lock.unlock() }; _out = newValue }
    }
    var err: Data {
        get { lock.lock(); defer { lock.unlock() }; return _err }
        set { lock.lock(); defer { lock.unlock() }; _err = newValue }
    }
}
