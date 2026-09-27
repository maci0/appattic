import Foundation
/// Bytes that need no quoting in a POSIX shell word.
@inline(__always)
func isSafeShellByte(_ c: UInt8) -> Bool {
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x5F || c == 0x40 || c == 0x25 || c == 0x2B || c == 0x3D ||
        c == 0x3A || c == 0x2C || c == 0x2E || c == 0x2F || c == 0x2D
}

public func shellQuote(_ value: String) -> String {
    if value.isEmpty { return "''" }
    // Byte scan: `CharacterSet.inverted` + `rangeOfCharacter` cost ~2.9 µs per
    // call, and this runs on every scripted path.
    //
    // The non-contiguous fallback applies the same predicate instead of
    // assuming "needs quoting": values bridged from NSString (Darwin) are not
    // contiguous, and guessing there made the same command quote differently
    // per platform.
    // Cold path (one call per script line): plain stdlib iteration.
    let needsQuote = value.utf8.contains { !isSafeShellByte($0) }
    if !needsQuote { return value }
    // Only `'` needs escaping inside single quotes.
    if !value.contains("'") { return "'" + value + "'" }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

/// Wrap a removal so an already-removed target is a no-op instead of a failure.
///
/// Generated scripts run under `set -e`, so an unguarded `pkgmgr remove` on a
/// target a previous run already deleted exits nonzero and `set -e` stops the
/// script there: the items after it never run. `present` is a read-only query
/// that exits 0 only while the target is still installed.
public func guardedRemoveCommand(present: String, remove: String) -> String {
    "if \(present) >/dev/null 2>&1; then \(remove); fi"
}

/// The two halves of a `guardedRemoveCommand` line, so the root wrapper and
/// the privilege check read the same shape instead of re-splitting the text.
public struct GuardedRemove: Equatable, Sendable {
    public var present: String
    public var action: String

    public init(present: String, action: String) {
        self.present = present
        self.action = action
    }
}

/// Split `if <present>; then <action>; fi`. Nil for anything else, including a
/// multi-line leftover removal, which is not a guard.
public func parseGuardedRemove(_ cmd: String) -> GuardedRemove? {
    let t = cmd.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("if "),
          let then = t.range(of: "; then "),
          let fi = t.range(of: "; fi", options: .backwards),
          then.upperBound < fi.lowerBound
    else { return nil }
    let present = String(t[t.index(t.startIndex, offsetBy: 3)..<then.upperBound])
    let action = String(t[then.upperBound..<fi.lowerBound]).trimmingCharacters(in: .whitespaces)
    return GuardedRemove(present: present, action: action)
}

/// Whether a wrapped line calls the `rootcmd` helper, so the script header
/// has to define it. A guarded removal escalates its action, not the line, so
/// the call is not always at the front.
public func callsRootHelper(_ cmd: String) -> Bool {
    cmd.hasPrefix("rootcmd ") || cmd.contains("; then rootcmd ")
}

/// Untrusted text (app names, paths, manager labels) for a `#` comment line in
/// a generated script. A newline ends the comment, and everything after it is a
/// command the script runs, so a folder named `Game\nrm -rf ~` would otherwise
/// inject a line into the script the UI runs after one preview. `shellQuote`
/// does not help here: a quoted newline is legal but the value is not quoted
/// when it lands in a comment.
public func shellComment(_ value: String) -> String {
    let flattened = value
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\u{2028}", with: " ")
        .replacingOccurrences(of: "\u{2029}", with: " ")
    return flattened.trimmingCharacters(in: .whitespaces)
}
