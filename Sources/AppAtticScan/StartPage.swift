import Foundation

/// The sidebar page a window opens on, named by `APPATTIC_PAGE`. The raw
/// values are the config spelling, lower-case and separated by dashes, the
/// same strings the Qt window accepts.
public enum StartPage: String, CaseIterable, Sendable {
    case overview
    case leftovers
    case stale
    case outdated
    case packages
    case disk
    case settings

    public static let nameList = StartPage.allCases.map(\.rawValue).joined(separator: ", ")
}

public struct StartPageResolution: Equatable, Sendable {
    public let page: StartPage
    /// The offending value when `APPATTIC_PAGE` named something that is not a
    /// page, so the caller can say so instead of opening the overview quietly.
    public let unknownValue: String?

    public var warning: String? {
        guard let unknownValue else { return nil }
        return "appattic: APPATTIC_PAGE=\"\(unknownValue)\" is not a page name; "
            + "opening overview. Valid values: \(StartPage.nameList)."
    }
}

/// Resolve `APPATTIC_PAGE`. Unset or empty opens the overview. An unknown name
/// is a misconfiguration, not a default, so it comes back as a warning and both
/// windows report it on stderr before falling back.
public func resolveStartPage(env: [String: String] = ProcessInfo.processInfo.environment) -> StartPageResolution {
    let raw = (env["APPATTIC_PAGE"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return StartPageResolution(page: .overview, unknownValue: nil) }
    guard let page = StartPage(rawValue: raw) else {
        return StartPageResolution(page: .overview, unknownValue: raw)
    }
    return StartPageResolution(page: page, unknownValue: nil)
}
