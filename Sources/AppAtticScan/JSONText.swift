import Foundation

/// True when `raw`, a JSON document, holds no control character inside a
/// string.
///
/// The `JSONDecoder` some Foundation versions ship defers two checks to its
/// string unwrap — an unescaped control character, and a string region that is
/// not valid UTF-8 — and that unwrap is a `try!`, so either one aborts the
/// process instead of raising an error. A settings file is written by hand and
/// a cache file is writable by anything running as the account, so neither may
/// take the process down.
///
/// `JSONSerialization`, which both readers run first, reports the control
/// character for an object *key*; whether it reports every *value* spelling is
/// not something this host can measure — corelibs rejects both, and the decoder
/// that traps is Darwin's — so this scan leans on it for neither and rejects
/// the character wherever it sits inside a string. Whitespace between tokens is
/// part of the format and stays legal, and invalid UTF-8 is left to
/// `JSONSerialization`, which already reports it.
///
/// An unterminated string, or a backslash that escapes nothing, is left to
/// `JSONSerialization` too: it has already rejected the document.
func jsonHasNoControlCharacterInString(_ raw: Data) -> Bool {
    var inString = false
    var escaped = false
    for byte in raw {
        if inString {
            if escaped {
                escaped = false
            } else if byte == 0x5C { // backslash
                escaped = true
            } else if byte == 0x22 { // quote
                inString = false
            } else if byte < 0x20 {
                return false
            }
        } else if byte == 0x22 {
            inString = true
        }
    }
    return true
}
