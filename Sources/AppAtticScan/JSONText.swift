import Foundation

/// True when `raw`, a JSON document, holds no control character inside a
/// string.
///
/// The `JSONDecoder` some Foundation versions ship defers two checks to its
/// string unwrap — an unescaped control character, and a string region that is
/// not valid UTF-8 — and that unwrap is a `try!`, so either one aborts the
/// process instead of raising an error. `JSONSerialization`, which both readers
/// run first, reports both for an object *key*; for a *value* it hands the
/// string back with the raw newline still in it, and the decoder then unwraps
/// that and traps. A settings file is written by hand and a cache file is
/// writable by anything running as the account, so neither may take the
/// process down: this scan runs first and the reader reports ordinary invalid
/// JSON instead.
///
/// Control characters are illegal inside a JSON string in every spelling of the
/// format; between tokens, `\n`, `\r` and `\t` are legal whitespace and stay
/// legal here. An unterminated string, or a backslash that escapes nothing, is
/// left to `JSONSerialization`, which has already rejected the document.
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
