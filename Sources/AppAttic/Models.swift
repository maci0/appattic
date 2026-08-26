import Foundation
import AppAtticScan

private enum DateFmt {
    static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let medium: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

func formatDate(_ iso: String?) -> String {
    guard let iso = iso, !iso.isEmpty else { return "-" }
    var date = DateFmt.frac.date(from: iso)
    if date == nil {
        date = DateFmt.basic.date(from: iso)
    }
    guard let d = date else { return String(iso.prefix(10)) }
    let days = Date().timeIntervalSince(d) / 86400
    if days < 1 { return "Today" }
    if days < 2 { return "Yesterday" }
    if days < 45 { return "\(Int(days)) days ago" }
    return DateFmt.medium.string(from: d)
}
