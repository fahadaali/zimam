import Foundation

// Records as the API sends and receives them (see api/DEVELOPMENT.md).
// Timestamps are Unix milliseconds; `updatedAt` is when the record was last
// edited on a device, and the newest edit wins.

public typealias Milliseconds = Int64

public extension Milliseconds {
    static var now: Milliseconds { Milliseconds(Date().timeIntervalSince1970 * 1000) }
}

public enum EntityKind: String, Codable, Sendable {
    case project, section, task, reminder, comment
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
    public enum Layout: String, Codable, Sendable { case list, kanban, calendar }

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
                tags: [String] = [], dueDate: String? = nil, dueTime: String? = nil, duePrayer: Prayer? = nil,
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
}

public struct ReminderRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var taskId: UUID
    public var kind: Kind
    /// ISO 8601 with offset, for `.time`.
    public var at: String?
    public var prayer: Prayer?
    public var offsetMinutes: Int?
    public var location: Location?
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

        public enum Trigger: String, Codable, Sendable { case arrive, leave }

        public init(latitude: Double, longitude: Double, radius: Double, name: String? = nil, trigger: Trigger) {
            self.latitude = latitude
            self.longitude = longitude
            self.radius = radius
            self.name = name
            self.trigger = trigger
        }
    }

    public init(id: UUID = UUID(), taskId: UUID, kind: Kind, at: String? = nil, prayer: Prayer? = nil, offsetMinutes: Int? = nil,
                location: Location? = nil, createdAt: Milliseconds? = nil, updatedAt: Milliseconds = .now) {
        self.id = id
        self.taskId = taskId
        self.kind = kind
        self.at = at
        self.prayer = prayer
        self.offsetMinutes = offsetMinutes
        self.location = location
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

    public var kind: EntityKind {
        switch self {
        case .project: .project
        case .section: .section
        case .task: .task
        case .reminder: .reminder
        case .comment: .comment
        }
    }
}

public struct User: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String?
    public var email: String?
    public var settings: Settings

    public struct Settings: Codable, Equatable, Sendable {
        public var calendar: CalendarKind
        public var prayerMethod: PrayerMethod
        /// 0 = Sunday.
        public var weekStart: Int
        /// IANA zone, so the server (Claude, ChatGPT) knows which day is "today".
        public var timeZone: String?
        /// Where the server computes prayer times for agendas. Set only when the user shares a location.
        public var location: Coordinate?

        public struct Coordinate: Codable, Equatable, Sendable {
            public var latitude: Double
            public var longitude: Double

            public init(latitude: Double, longitude: Double) {
                self.latitude = latitude
                self.longitude = longitude
            }
        }

        public init(calendar: CalendarKind = .hijri, prayerMethod: PrayerMethod = .ummAlQura, weekStart: Int = 0,
                    timeZone: String? = nil, location: Coordinate? = nil) {
            self.calendar = calendar
            self.prayerMethod = prayerMethod
            self.weekStart = weekStart
            self.timeZone = timeZone
            self.location = location
        }
        private enum CodingKeys: String, CodingKey { case calendar, prayerMethod, weekStart, timeZone, location }

        /// Sends `location: null` when there is none, so turning sharing off clears it on the server.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(calendar, forKey: .calendar)
            try c.encode(prayerMethod, forKey: .prayerMethod)
            try c.encode(weekStart, forKey: .weekStart)
            try c.encodeIfPresent(timeZone, forKey: .timeZone)
            try c.encode(location, forKey: .location)
        }
    }
}
