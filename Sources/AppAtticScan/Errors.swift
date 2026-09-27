import Foundation

/// Recoverable I/O failures from cache and settings persistence.
public enum AppAtticIOError: Error, Equatable, LocalizedError, CustomStringConvertible, Sendable {
    case createDirectoryFailed(path: String, message: String)
    case encodeFailed(message: String)
    case writeFailed(path: String, message: String)
    case readFailed(path: String, message: String)
    case decodeFailed(path: String, message: String)

    /// The cache and settings paths sit under the account home, so the account
    /// name is in them. `description` returns the raw path; callers that print
    /// or log an error wrap the line in `redactHomePaths` so the account name
    /// never leaves the machine.
    public var errorDescription: String? {
        description
    }

    public var description: String {
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
