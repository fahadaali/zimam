import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The in-app assistant (api/src/routes/assistant.ts). Nothing it returns is saved:
// the app shows the suggestion and the user accepts it, then it syncs as usual.

/// `POST /v1/assistant/parse`: a task read from one natural-language sentence.
public struct TaskSuggestion: Decodable, Equatable, Sendable {
    public var title: String
    public var notes: String?
    /// Local Gregorian day, "2026-10-15".
    public var dueDate: String?
    /// "HH:mm". The server drops it when the task is tied to a prayer.
    public var dueTime: String?
    public var duePrayer: Prayer?
    public var duePrayerOffset: Int?
    public var priority: TaskPriority
    public var tags: [String]
    /// Only one of the user's own projects; the server drops anything else.
    public var projectId: UUID?

    public init(title: String, notes: String? = nil, dueDate: String? = nil, dueTime: String? = nil, duePrayer: Prayer? = nil,
                duePrayerOffset: Int? = nil, priority: TaskPriority = .none, tags: [String] = [], projectId: UUID? = nil) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.duePrayer = duePrayer
        self.duePrayerOffset = duePrayerOffset
        self.priority = priority
        self.tags = tags
        self.projectId = projectId
    }

    private enum CodingKeys: String, CodingKey {
        case title, notes, dueDate, dueTime, duePrayer, duePrayerOffset, priority, tags, projectId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
        dueTime = try c.decodeIfPresent(String.self, forKey: .dueTime)
        // An unknown prayer is dropped rather than failing the whole suggestion.
        duePrayer = (try? c.decodeIfPresent(String.self, forKey: .duePrayer)).flatMap(Prayer.init(rawValue:))
        duePrayerOffset = try c.decodeIfPresent(Int.self, forKey: .duePrayerOffset)
        // The assistant names the priority ("none", "low", "medium", "high"); tasks store 0 to 3.
        if let name = try? c.decodeIfPresent(String.self, forKey: .priority) {
            priority = TaskPriority(name: name) ?? TaskPriority.none
        } else if let level = try? c.decodeIfPresent(Int.self, forKey: .priority) {
            priority = TaskPriority(rawValue: level) ?? TaskPriority.none
        } else {
            priority = TaskPriority.none
        }
        tags = (try c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        projectId = (try? c.decodeIfPresent(String.self, forKey: .projectId)).flatMap(UUID.init(uuidString:))
    }
}

public extension TaskPriority {
    /// The assistant's names for priorities: "none", "low", "medium", "high".
    init?(name: String) {
        switch name.lowercased() {
        case "none": self = TaskPriority.none
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        default: return nil
        }
    }

    /// «عالية», «متوسطة», «منخفضة», «بلا أولوية».
    var arabicName: String {
        switch self {
        case .none: "بلا أولوية"
        case .low: "منخفضة"
        case .medium: "متوسطة"
        case .high: "عالية"
        }
    }
}

/// `GET /v1/assistant/summary`: the morning summary of a day, in Arabic.
public struct DaySummary: Decodable, Equatable, Sendable {
    /// The day summarised, "2026-10-15".
    public let date: String
    public let text: String

    public init(date: String, text: String) {
        self.date = date
        self.text = text
    }
}

/// `POST /v1/assistant/breakdown`: three to eight short subtask titles.
public struct SubtaskSuggestions: Decodable, Equatable, Sendable {
    public let subtasks: [String]
}

/// Why an assistant request failed, with the Arabic sentence the app shows.
/// The assistant never blocks normal use: the app shows this in place of the suggestion.
public enum AssistantProblem: Equatable, Sendable {
    /// No connection. The assistant needs the server.
    case offline
    /// `429 ai_quota_exceeded`: the month's requests are used. `resetsOn` is "2026-11-01".
    case quotaExceeded(limit: Int?, resetsOn: String?)
    /// `503 ai_unavailable`: the provider failed or answered with something unusable.
    case unavailable
    /// `404`: the server does not know the task yet, or the user cannot see it.
    case notFound
    /// `400 invalid`: empty or too long text.
    case invalidInput
    /// `401`: the session ended; the next sync signs out.
    case signedOut
    /// `403 pro_required`: the assistant needs «زمام الاحترافية» (only when the server enforces plans).
    /// The app offers the paywall with this message.
    case proRequired
    case other

    public init(_ error: Error) {
        if let api = error as? APIError {
            switch (api.status, api.code) {
            case (_, "pro_required"): self = .proRequired
            case (429, _), (_, "ai_quota_exceeded"): self = .quotaExceeded(limit: api.limit, resetsOn: api.resetsOn)
            case (503, _), (_, "ai_unavailable"): self = .unavailable
            case (404, _): self = .notFound
            case (400, _): self = .invalidInput
            case (401, _): self = .signedOut
            default: self = .other
            }
        } else if NetworkFailure.isOffline(error) {
            self = .offline
        } else {
            self = .other
        }
    }

    /// The sentence shown in the suggestion card, with dates in both calendars.
    public func message(formatter: DualDateFormatter = DualDateFormatter()) -> String {
        switch self {
        case .offline:
            return "المساعد يحتاج اتصالاً بالإنترنت. أضف المهمة يدوياً أو حاول حين يعود الاتصال."
        case let .quotaExceeded(limit, resetsOn):
            var text = "استعملت كل طلبات المساعد لهذا الشهر"
            if let limit {
                text += " (الحد \(limit.formatted(.number.locale(formatter.locale))))"
            }
            text += "، ولم يبقَ منها شيء."
            if let day = resetsOn, let date = formatter.date(fromDay: day) {
                text += " تتجدد في \(formatter.dual(date))."
            }
            return text
        case .unavailable:
            return "المساعد غير متاح الآن. حاول بعد قليل."
        case .notFound:
            return "لم تصل هذه المهمة إلى الخادم بعد. زامِن ثم حاول مرة أخرى."
        case .invalidInput:
            return "تعذّر فهم النص. اكتب جملة أقصر وأوضح."
        case .signedOut:
            return "انتهت الجلسة. سجّل الدخول مرة أخرى."
        case .proRequired:
            return "المساعد الذكي من مزايا «زمام الاحترافية». اشترك لتستعمله."
        case .other:
            return "تعذّر الوصول إلى المساعد. حاول مرة أخرى."
        }
    }
}

/// Transport failures that mean "no connection", as opposed to a server answer.
public enum NetworkFailure {
    public static func isOffline(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .timedOut, .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
