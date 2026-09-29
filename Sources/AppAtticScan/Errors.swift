import Foundation

/// Recoverable I/O failures from scan-cache persistence. Settings have their
/// own type: `SettingsError`, because a settings failure is one the user is
/// asked to fix by hand rather than one a rescan clears.
public enum AppAtticIOError: Error, Equatable, LocalizedError, CustomStringConvertible, Sendable {
    case createDirectoryFailed(path: String, message: String)
    case encodeFailed(message: String)
    case writeFailed(path: String, message: String)
    case readFailed(path: String, message: String)
    case decodeFailed(path: String, message: String)

    /// The cache and settings paths sit under the account home, so the account
    /// name is in them. The composed line is redacted here, exactly as
    /// `SettingsError.description` and `DiskRootError.description` do it: the
    /// wrap used to be every caller's job, and a caller that printed
    /// `localizedDescription` without it — the CLI's own top-level handler, a
    /// future one, the error bar — leaked the account name. The callers'
    /// `redactHomePaths` stays, and is a no-op on an already-redacted line.
    public var errorDescription: String? {
        description
    }

    public var description: String {
        redactHomePaths(rawDescription)
    }

    private var rawDescription: String {
        switch self {
        case .createDirectoryFailed(let path, let message):
            return "Could not create directory \(path): \(message)"
        case .encodeFailed(let message):
            return "Could not encode data: \(message)"
        case .writeFailed(let path, let message):
            return "Could not write \(path): \(message)"
        case .readFailed(let path, let message):
            return "Could not read \(path): \(message)"
        case .decodeFailed(let path, let message):
            return "Could not decode \(path): \(message)"
        }
    }
}
