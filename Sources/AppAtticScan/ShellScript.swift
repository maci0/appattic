import Foundation
/// Bytes that need no quoting in a POSIX shell word.
@inline(__always)
func isSafeShellByte(_ c: UInt8) -> Bool {
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x5F || c == 0x40 || c == 0x25 || c == 0x2B || c == 0x3D ||
        c == 0x3A || c == 0x2C || c == 0x2E || c == 0x2F || c == 0x2D
}

/// Quote a value for a POSIX shell word. An empty value becomes `''` and a
/// value with no unsafe byte is passed through unquoted.
public func shellQuote(_ value: String) -> String {
    if value.isEmpty { return "''" }
    // Byte scan: `CharacterSet.inverted` + `rangeOfCharacter` cost ~2.9 µs per
    // call, and this runs on every scripted path.
    let needsQuote = value.utf8.contains { !isSafeShellByte($0) }
    if !needsQuote { return value }
    // Only `'` needs escaping inside single quotes.
    if !value.contains("'") { return "'" + value + "'" }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

/// A scanned name is safe to splice as a command argument.
///
/// `shellQuote` leaves a leading `-` unquoted, because every byte of `--force`
/// is shell-safe, so the package manager reads the name as an option rather
/// than as its argument. A name here comes from a registry, a tap, or the
/// scan cache, so it is not this app's to trust. No real package or formula is
/// named this way, so a caller that sees `false` drops the row instead of
/// emitting a command. The Zig core applies the same rule in
/// `jsonbuf.isSafeCmdIdent`.
public func isSafeCommandArgument(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("-")
}

/// The ` >/dev/null 2>&1` the guard wrapper puts behind the query, and the one
/// `parseGuardedRemove` takes back off it.
let guardSilence = " >/dev/null 2>&1"

/// `if <present> >/dev/null 2>&1; then <action>; fi`, the wrapper a removal and
/// a guarded upgrade share. `present` is a read-only query that exits 0 only
/// while the target is still in the state the action acts on.
///
/// The redirect belongs to the wrapper rather than to the query, so the pair
/// with `parseGuardedRemove` is an inverse: the parse hands the query back
/// without it, and writing the two halves out again puts exactly one back. The
/// Zig core writes the guard without it at all (`core/src/guarded_remove.zig`
/// `writeNameGuard`), and the Qt `rootcmd` escalation reads both spellings.
public func guardedCommand(present: String, action: String) -> String {
    "if \(present)\(guardSilence); then \(action); fi"
}

/// Wrap a removal so an already-removed target is a no-op instead of a failure.
///
/// Generated scripts run under `set -e`, so an unguarded `pkgmgr remove` on a
/// target a previous run already deleted exits nonzero and `set -e` stops the
/// script there: the items after it never run.
public func guardedRemoveCommand(present: String, remove: String) -> String {
    guardedCommand(present: present, action: remove)
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
    // The line has to end at the `; fi`: anything after it is a command the
    // guard does not cover, and `withRootCmd` rebuilds the line from the two
    // halves alone, so an unrecognised tail would be dropped instead of run.
    guard t.hasPrefix("if "),
          t.hasSuffix("; fi"),
          let then = t.range(of: "; then "),
          let fi = t.range(of: "; fi", options: .backwards),
          then.upperBound < fi.lowerBound
    else { return nil }
    // Nothing may follow the guard: the callers judge only these two halves,
    // so a tail after the last `; fi` would run unjudged.
    guard t[fi.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    // The query ends where the `; then ` starts — including the separator made
    // it a half no writer produces — and the wrapper's redirect comes off with
    // it: callers judge and re-run the query, not the plumbing that silences
    // it, and `guardedCommand` puts it back when the halves are written out.
    var present = String(t[t.index(t.startIndex, offsetBy: 3)..<then.lowerBound])
    if present.hasSuffix(guardSilence) { present.removeLast(guardSilence.count) }
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
/// when it lands in a comment. Control scalars go too, because the script is
/// printed to a terminal that executes them.
public func shellComment(_ value: String) -> String {
    let flattened = value
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\u{2028}", with: " ")
        .replacingOccurrences(of: "\u{2029}", with: " ")
    // `--dry-run` prints the script, so a control scalar left in a name is
    // read by the terminal running it: `ESC ] 0 ;` retitles the window and
    // `ESC [ 2 J` clears the rows the user is about to approve. Newlines are
    // flattened above, so they stay readable spaces; the rest become U+FFFD,
    // the same marker `terminalSafe` uses.
    var scalars = String.UnicodeScalarView()
    for scalar in flattened.unicodeScalars {
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) {
            scalars.append("\u{FFFD}")
        } else {
            scalars.append(scalar)
        }
    }
    return String(scalars).trimmingCharacters(in: .whitespaces)
}
