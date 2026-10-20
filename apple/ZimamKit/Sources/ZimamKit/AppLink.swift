import Foundation

/// Links into the app, from its widgets: `zimam://today`, `zimam://calendar`,
/// `zimam://day/2026-10-15` (the calendar on that day), `zimam://task/<id>` (the task's details)
/// and `zimam://prayer` («أوقات الصلاة»).
/// Invite links (`zimam://join/<code>`) are not these; `InviteCode` reads them.
public enum AppLink: Equatable, Hashable, Sendable {
    case today
    case calendar
    /// The API's local day, "2026-10-15".
    case day(String)
    case task(UUID)
    case prayer

    public var url: URL {
        let scheme = ZimamWeb.appScheme
        switch self {
        case .today: return URL(string: "\(scheme)://today")!
        case .calendar: return URL(string: "\(scheme)://calendar")!
        case .day(let day):
            // Built from parts, so a day string with a space or other stray character is
            // percent-encoded rather than making URL(string:) return nil.
            var components = URLComponents()
            components.scheme = scheme
            components.host = "day"
            components.path = "/" + day
            return components.url!
        case .task(let id): return URL(string: "\(scheme)://task/\(id.uuidString)")!
        case .prayer: return URL(string: "\(scheme)://prayer")!
        }
    }

    /// Reads one of the links above; nil for anything else.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == ZimamWeb.appScheme, let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        switch (host, parts.count) {
        case ("today", 0): self = .today
        case ("calendar", 0): self = .calendar
        case ("prayer", 0): self = .prayer
        case ("day", 1):
            guard Self.isDay(parts[0]) else { return nil }
            self = .day(parts[0])
        case ("task", 1):
            guard let id = UUID(uuidString: parts[0]) else { return nil }
            self = .task(id)
        default:
            return nil
        }
    }

    /// "2026-10-15": four, two and two digits.
    static func isDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}
