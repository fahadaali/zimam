import Foundation

// Records as the API sends and receives them (see api/DEVELOPMENT.md).
// Timestamps are Unix milliseconds; `updatedAt` is when the record was last
// edited on a device, and the newest edit wins.

public typealias Milliseconds = Int64

public extension Milliseconds {
    static var now: Milliseconds { Milliseconds(Date().timeIntervalSince1970 * 1000) }
}

public enum EntityKind: String, Codable, Sendable {
    case project, section, task, reminder, comment, place
}

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case todo, doing, done
}

/// 0 none, 1 low, 2 medium, 3 high.
public enum TaskPriority: Int, Codable, Sendable, CaseIterable {
    case none = 0, low, medium, high
}

public struct ProjectRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var ownerId: UUID?
    public var parentId: UUID?
    public var kind: Kind
    public var name: String
    public var view: Layout
    public var sortOrder: Double
    public var archivedAt: Milliseconds?
    public var createdAt: Milliseconds?
    public var updatedAt: Milliseconds

    public enum Kind: String, Codable, Sendable { case project, folder }
    /// How the project opens. `timeline` is «المخطط الزمني»; the app asks the server for it
    /// (`include=timeline`), and a view this build does not know reads as a list.
    public enum Layout: String, Codable, Sendable {
        case list, kanban, calendar, timeline

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Layout(rawValue: raw) ?? .list
        }
    }

    public init(id: UUID = UUID(), ownerId: UUID? = nil, parentId: UUID? = nil, kind: Kind = .project, name: String,
                view: Layout = .list, sortOrder: Double = 0, archivedAt: Milliseconds? = nil, createdAt: Milliseconds? = nil,
                updatedAt: Milliseconds = .now) {
        self.id = id
        self.ownerId = ownerId
        self.parentId = parentId
        self.kind = kind
        self.name = name
        self.view = view
        self.sortOrder = sortOrder
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A view this build does not know, as the server sent it. The project opens as a list, and
    /// the value goes back unchanged on the next edit unless the user picks another view, so a
    /// newer app's or the web's choice is never overwritten.
    public var unknownView: String?

    private enum CodingKeys: String, CodingKey {
        case id, ownerId, parentId, kind, name, view, sortOrder, archivedAt, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ownerId = try c.decodeIfPresent(UUID.self, forKey: .ownerId)
        parentId = try c.decodeIfPresent(UUID.self, forKey: .parentId)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        let raw = try c.decodeIfPresent(String.self, forKey: .view) ?? Layout.list.rawValue
        view = Layout(rawValue: raw) ?? .list
        unknownView = Layout(rawValue: raw) == nil ? raw : nil
        sortOrder = try c.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        archivedAt = try c.decodeIfPresent(Milliseconds.self, forKey: .archivedAt)
        createdAt = try c.decodeIfPresent(Milliseconds.self, forKey: .createdAt)
        updatedAt = try c.decode(Milliseconds.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(ownerId, forKey: .ownerId)
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(view == .list ? (unknownView ?? view.rawValue) : view.rawValue, forKey: .view)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct SectionRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var sortOrder: Double
    public var createdAt: Milliseconds?
    public var updatedAt: Milliseconds

    public init(id: UUID = UUID(), projectId: UUID, name: String, sortOrder: Double = 0, createdAt: Milliseconds? = nil,
                updatedAt: Milliseconds = .now) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TaskRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var ownerId: UUID?
    public var projectId: UUID?
    public var sectionId: UUID?
    public var parentId: UUID?
    public var title: String
    public var notes: String?
    public var status: TaskStatus
    public var priority: TaskPriority
    public var tags: [String]
    /// Local Gregorian day, "2026-10-15". Hijri is derived for display.
    public var dueDate: String?
    /// The first day of a task that spans days, up to `dueDate` (inclusive); nil for a one-day
    /// task. Only with a `dueDate` and never after it: the server rejects anything else.
    public var startDate: String?
    /// "HH:mm", local.
    public var dueTime: String?
    public var duePrayer: Prayer?
    /// Minutes after (positive) or before (negative) `duePrayer`.
    public var duePrayerOffset: Int?
    /// RFC 5545 RRULE.
    public var recurrence: String?
    public var assigneeId: UUID?
    public var sortOrder: Double
    public var completedAt: Milliseconds?
    public var createdAt: Milliseconds?
    public var updatedAt: Milliseconds

    public init(id: UUID = UUID(), ownerId: UUID? = nil, projectId: UUID? = nil, sectionId: UUID? = nil, parentId: UUID? = nil,
                title: String, notes: String? = nil, status: TaskStatus = .todo, priority: TaskPriority = .none,
                tags: [String] = [], dueDate: String? = nil, startDate: String? = nil, dueTime: String? = nil, duePrayer: Prayer? = nil,
                duePrayerOffset: Int? = nil, recurrence: String? = nil, assigneeId: UUID? = nil, sortOrder: Double = 0,
                completedAt: Milliseconds? = nil, createdAt: Milliseconds? = nil, updatedAt: Milliseconds = .now) {
        self.id = id
        self.ownerId = ownerId
        self.projectId = projectId
        self.sectionId = sectionId
        self.parentId = parentId
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.tags = tags
        self.dueDate = dueDate
        self.startDate = startDate
        self.dueTime = dueTime
        self.duePrayer = duePrayer
        self.duePrayerOffset = duePrayerOffset
        self.recurrence = recurrence
        self.assigneeId = assigneeId
        self.sortOrder = sortOrder
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, ownerId, projectId, sectionId, parentId, title, notes, status, priority, tags, dueDate, startDate, dueTime,
             duePrayer, duePrayerOffset, recurrence, assigneeId, sortOrder, completedAt, createdAt, updatedAt
    }

    /// As the synthesized encoding, except that `startDate` is always sent, `null` when there is
    /// none: the server keeps a stored start day for a record without the field (apps that predate
    /// it), so leaving it out would never clear it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(ownerId, forKey: .ownerId)
        try c.encodeIfPresent(projectId, forKey: .projectId)
        try c.encodeIfPresent(sectionId, forKey: .sectionId)
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(status, forKey: .status)
        try c.encode(priority, forKey: .priority)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(dueDate, forKey: .dueDate)
        try c.encode(startDate, forKey: .startDate)
        try c.encodeIfPresent(dueTime, forKey: .dueTime)
        try c.encodeIfPresent(duePrayer, forKey: .duePrayer)
        try c.encodeIfPresent(duePrayerOffset, forKey: .duePrayerOffset)
        try c.encodeIfPresent(recurrence, forKey: .recurrence)
        try c.encodeIfPresent(assigneeId, forKey: .assigneeId)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct ReminderRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var taskId: UUID
    public var kind: Kind
    /// ISO 8601 with offset, for `.time`. On `.location` it is the time that competes with the
    /// place: the reminder fires once, at whichever comes first (`ReminderFiring`).
    public var at: String?
    public var prayer: Prayer?
    public var offsetMinutes: Int?
    public var location: Location?
    /// When a location reminder with a time fired at the place, before its time. Left out when
    /// nil, so the server keeps what another device set.
    public var firedAt: Milliseconds?
    public var createdAt: Milliseconds?
    public var updatedAt: Milliseconds

    public enum Kind: String, Codable, Sendable { case time, prayer, location }

    public struct Location: Codable, Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        /// Meters, 50 to 10,000.
        public var radius: Double
        public var name: String?
        public var trigger: Trigger
        /// The saved place («أماكني») this copy came from. The server keeps the copy in step
        /// when the place changes, and clears this when it is deleted.
        public var placeId: UUID?

        public enum Trigger: String, Codable, Sendable { case arrive, leave }

        public init(latitude: Double, longitude: Double, radius: Double, name: String? = nil, trigger: Trigger,
                    placeId: UUID? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.radius = radius
            self.name = name
            self.trigger = trigger
            self.placeId = placeId
        }

        /// A reminder's copy of a saved place.
        public init(place: PlaceRecord, trigger: Trigger) {
            self.init(latitude: place.latitude, longitude: place.longitude, radius: place.radius, name: place.name,
                      trigger: trigger, placeId: place.id)
        }
    }

    public init(id: UUID = UUID(), taskId: UUID, kind: Kind, at: String? = nil, prayer: Prayer? = nil, offsetMinutes: Int? = nil,
                location: Location? = nil, firedAt: Milliseconds? = nil, createdAt: Milliseconds? = nil,
                updatedAt: Milliseconds = .now) {
        self.id = id
        self.taskId = taskId
        self.kind = kind
        self.at = at
        self.prayer = prayer
        self.offsetMinutes = offsetMinutes
        self.location = location
        self.firedAt = firedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A saved place («أماكني»): «البيت», «العمل», «الاستراحة». Personal, synced with
/// `include=place`, and reused by location reminders, which keep their own copy of it.
public struct PlaceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// Meters, 50 to 10,000.
    public var radius: Double
    public var createdAt: Milliseconds?
    public var updatedAt: Milliseconds

    public init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, radius: Double,
                createdAt: Milliseconds? = nil, updatedAt: Milliseconds = .now) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CommentRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var taskId: UUID
    public var authorId: UUID?
    public var body: String
    public var createdAt: Milliseconds?
    public var updatedAt: Milliseconds
}

public enum AnyRecord: Equatable, Sendable {
    case project(ProjectRecord)
    case section(SectionRecord)
    case task(TaskRecord)
    case reminder(ReminderRecord)
    case comment(CommentRecord)
    case place(PlaceRecord)

    public var kind: EntityKind {
        switch self {
        case .project: .project
        case .section: .section
        case .task: .task
        case .reminder: .reminder
        case .comment: .comment
        case .place: .place
        }
    }
}

public struct User: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String?
    public var email: String?
    public var settings: Settings
    /// When the photo last changed (milliseconds), or nil without one (`APIClient.avatar()`).
    public var avatarVersion: Milliseconds?

    public struct Settings: Codable, Equatable, Sendable {
        public var calendar: CalendarKind
        public var prayerMethod: PrayerMethod
        /// 0 = Sunday.
        public var weekStart: Int
        /// IANA zone, so the server (Claude, ChatGPT) knows which day is "today".
        public var timeZone: String?
        /// Where the server computes prayer times for agendas. Set only when the user shares a location.
        public var location: Coordinate?
        /// Asr by the majority or the Hanafi madhab; nil (an older server or account) is the majority.
        public var asrMadhab: AsrMadhab?
        /// Adhan and iqama alerts per prayer; nil has none. They sync, and each device schedules its own.
        public var prayerAlerts: PrayerAlertSettings?

        public struct Coordinate: Codable, Equatable, Sendable {
            public var latitude: Double
            public var longitude: Double

            public init(latitude: Double, longitude: Double) {
                self.latitude = latitude
                self.longitude = longitude
            }
        }

        public init(calendar: CalendarKind = .hijri, prayerMethod: PrayerMethod = .ummAlQura, weekStart: Int = 0,
                    timeZone: String? = nil, location: Coordinate? = nil, asrMadhab: AsrMadhab? = nil,
                    prayerAlerts: PrayerAlertSettings? = nil) {
            self.calendar = calendar
            self.prayerMethod = prayerMethod
            self.weekStart = weekStart
            self.timeZone = timeZone
            self.location = location
            self.asrMadhab = asrMadhab
            self.prayerAlerts = prayerAlerts
        }
        private enum CodingKeys: String, CodingKey {
            case calendar, prayerMethod, weekStart, timeZone, location, asrMadhab, prayerAlerts
        }

        /// Sends `location: null` when there is none, so turning sharing off clears it on the server.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(calendar, forKey: .calendar)
            try c.encode(prayerMethod, forKey: .prayerMethod)
            try c.encode(weekStart, forKey: .weekStart)
            try c.encodeIfPresent(timeZone, forKey: .timeZone)
            try c.encode(location, forKey: .location)
            try c.encodeIfPresent(asrMadhab, forKey: .asrMadhab)
            try c.encodeIfPresent(prayerAlerts, forKey: .prayerAlerts)
        }
    }
}
