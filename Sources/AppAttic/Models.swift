import Foundation
import AppAtticScan

private enum DateFmt {
    static let medium: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

func formatDate(_ iso: String?) -> String {
    guard let iso = iso, !iso.isEmpty else { return "-" }
    guard let d = parseISODate(iso) else { return String(iso.prefix(10)) }
    guard let days = calendarDaysSince(d) else { return DateFmt.medium.string(from: d) }
    if days <= 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days < 45 { return "\(days) days ago" }
    return DateFmt.medium.string(from: d)
}
