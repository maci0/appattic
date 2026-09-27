import Foundation
public enum PlatformOverride {
    // Read from every collector, including `pmap` worker threads, so a scan
    // takes one snapshot here and the test hooks that set it take the same lock.
    // A plain `static var` is a torn read under a concurrent set, which lets
    // sibling workers of one scan take different platform branches.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedLinux: Bool?

    public static var linux: Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedLinux
        }
        set {
            lock.lock()
            storedLinux = newValue
            lock.unlock()
        }
    }

    public static var isLinux: Bool {
        if let linux { return linux }
        #if os(Linux)
        return true
        #else
        return false
        #endif
    }
    public static var isDarwin: Bool { !isLinux }
}

public func parseOsRelease(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    // Byte scan: `trimmingCharacters` + `firstIndex(of:)` per line cost ~26 µs
    // for a 12-line os-release. Keys/values are ASCII, so the only String
    // allocations are the one per key and value.
    //
    // Split on raw LF/CR bytes, not `split(separator: "\n")`: Swift treats
    // "\r\n" as one grapheme cluster, so that never splits a CRLF file.
    let bytes = Array(text.utf8)
    let n = bytes.count
    func emit(_ s: Int, _ e: Int) {
        var (a, b) = (s, e)
        while a < b, bytes[a] == 0x20 || bytes[a] == 0x09 { a += 1 }
        while b > a, bytes[b - 1] == 0x20 || bytes[b - 1] == 0x09 { b -= 1 }
        guard a < b, bytes[a] != 0x23 /* # */ else { return }
        var eq = a
        while eq < b, bytes[eq] != 0x3D /* = */ { eq += 1 }
        // The key ends at the `=`, so the whitespace in front of it is padding
        // and not part of the name: `ID = ubuntu` is the `ID` field, and a key
        // that kept the space would not answer the `ID` a caller looks up.
        var ke = eq
        while ke > a, bytes[ke - 1] == 0x20 || bytes[ke - 1] == 0x09 { ke -= 1 }
        // `a == ke` is a line whose key is empty, which is not a field either.
        guard eq < b, a < ke else { return }
        var (vs, ve) = (eq + 1, b)
        while vs < ve, bytes[vs] == 0x20 || bytes[vs] == 0x09 { vs += 1 }
        while ve > vs, bytes[ve - 1] == 0x20 || bytes[ve - 1] == 0x09 { ve -= 1 }
        if ve - vs >= 2 {
            let f = bytes[vs]
            let l = bytes[ve - 1]
            if (f == 0x22 && l == 0x22) || (f == 0x27 && l == 0x27) { vs += 1; ve -= 1 }
        }
        out[String(decoding: bytes[a..<ke], as: UTF8.self)] =
            String(decoding: bytes[vs..<ve], as: UTF8.self)
    }
    var i = 0
    while i < n {
        var j = i
        while j < n, bytes[j] != 0x0A, bytes[j] != 0x0D { j += 1 }
        emit(i, j)
        // One CRLF (or run of breaks) is one boundary.
        while j < n, bytes[j] == 0x0A || bytes[j] == 0x0D { j += 1 }
        i = j
    }
    return out
}

public func linuxDistroFamily(osRelease: String) -> String {
    let fields = parseOsRelease(osRelease)
    let id = (fields["ID"] ?? "").posixLowercased()
    let like = (fields["ID_LIKE"] ?? "").posixLowercased()
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    let tokens = ([id] + like).filter { !$0.isEmpty }
    func matches(_ needles: Set<String>) -> Bool {
        tokens.contains { needles.contains($0) }
    }
    if matches(["arch", "archlinux", "manjaro", "endeavouros", "garuda", "cachyos", "artix", "archarm"]) {
        return "arch"
    }
    if matches(["fedora", "rhel", "centos", "rocky", "almalinux", "alma", "nobara", "ol", "amzn"]) {
        return "fedora"
    }
    if tokens.contains(where: { $0.contains("suse") || $0 == "sles" || $0.hasPrefix("opensuse") }) {
        return "suse"
    }
    if matches(["debian", "ubuntu", "linuxmint", "pop", "elementary", "raspbian", "kali", "zorin", "neon"]) {
        return "debian"
    }
    return "unknown"
}

/// Distro package manager used for orphans and outdated queries.
///
/// `dpkg` is not a query target: `resolveDistroPackageManager` never returns
/// it, and `dpkg -l` rc rows are collected inside the `.apt` query because
/// both belong to Debian. The case still exists so `DistroPackageManager(rawValue:)`
/// admits every `PackageEntry.manager` a collector can emit, which is what
/// `PackageEntry.canMarkManual` asks.
public enum DistroPackageManager: String, Sendable {
    case pacman
    case apt
    case dpkg
    case dnf
    // The pinned toolchain (Swift 5.10.1) fails to resolve a case literally
    // spelled `zypper` on this enum, failing the build with "has no member".
    // The raw value is what every manager string, JSON field, and generated
    // script compares against, so renaming the case fixes the compiler without
    // touching observable output.
    case zypperPkg = "zypper"
}

/// Family from os-release, then PATH order pacman, dnf, zypper, apt.
public func resolveDistroPackageManager(family: String, which: WhichFn) -> DistroPackageManager? {
    switch family {
    case "arch":
        return .pacman
    case "debian":
        return .apt
    case "fedora":
        return .dnf
    case "suse":
        return DistroPackageManager.zypperPkg
    default:
        break
    }
    if which("pacman") != nil { return .pacman }
    if which("dnf5") != nil || which("dnf") != nil || which("yum") != nil { return .dnf }
    if which("zypper") != nil { return DistroPackageManager.zypperPkg }
    if which("apt-get") != nil || which("apt") != nil { return .apt }
    return nil
}

public func linuxOsReleaseText(
    readFile: (String) -> String? = { path in
        readUTF8File(path)
    }
) -> String {
    readFile("/etc/os-release") ?? readFile("/usr/lib/os-release") ?? ""
}
