import Foundation

/// Apple Reminders imported on the device: the app reads EventKit, turns each reminder into
/// these plain values, and `plan` decides what to add. Each list becomes a project, each
/// reminder a task, and the records go through `Store` like any edit, so they sync.
///
/// A re-import skips what was imported before: the caller remembers each reminder's
/// `calendarItemExternalIdentifier` with the task it became (`Plan.taskRefs`), and each list
/// with its project (`Plan.projectRefs`), and passes them back as `knownTasks`/`knownProjects`.
public enum AppleRemindersImport {
    /// The id the import screen uses for this source; the server does not know it.
    public static let sourceId = "apple-reminders"

    /// A reminders list (an `EKCalendar` of type reminder).
    public struct List: Equatable, Hashable, Identifiable, Sendable {
        /// `calendarIdentifier`.
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// A repeat rule as EventKit gives it. `isExact` is false when it had parts Zimam
    /// cannot express (a day of the month, «the first Monday»…).
    public struct Repeat: Equatable, Sendable {
        public var frequency: Recurrence.Frequency
        public var interval: Int
        public var weekdays: [Weekday]
        public var count: Int?
        public var until: Date?
        public var isExact: Bool

        public init(frequency: Recurrence.Frequency, interval: Int = 1, weekdays: [Weekday] = [], count: Int? = nil,
                    until: Date? = nil, isExact: Bool = true) {
            self.frequency = frequency
            self.interval = interval
            self.weekdays = weekdays
            self.count = count
            self.until = until
            self.isExact = isExact
        }
    }

    /// One reminder (`EKReminder`) as plain values.
    public struct Item: Equatable, Sendable {
        /// `calendarItemExternalIdentifier` (the same on every device), or the local identifier when there is none.
        public var externalId: String
        public var listId: String
        public var title: String
        public var notes: String?
        public var url: URL?
        /// `dueDateComponents`: a day, or a day with a time; `timeZone` nil means floating (local).
        public var due: DateComponents?
        /// EventKit's 0 (none) and 1–9 (1 highest).
        public var priority: Int
        public var isCompleted: Bool
        public var completedAt: Date?
        /// Alarm times, already resolved to dates.
        public var alarms: [Date]
        public var repeatRule: Repeat?

        public init(externalId: String, listId: String, title: String, notes: String? = nil, url: URL? = nil,
                    due: DateComponents? = nil, priority: Int = 0, isCompleted: Bool = false, completedAt: Date? = nil,
                    alarms: [Date] = [], repeatRule: Repeat? = nil) {
            self.externalId = externalId
            self.listId = listId
            self.title = title
            self.notes = notes
            self.url = url
            self.due = due
            self.priority = priority
            self.isCompleted = isCompleted
            self.completedAt = completedAt
            self.alarms = alarms
            self.repeatRule = repeatRule
        }
    }

    /// What an import adds.
    public struct Plan: Equatable, Sendable {
        public var projects: [ProjectRecord] = []
        public var tasks: [TaskRecord] = []
        public var reminders: [ReminderRecord] = []
        /// New links to remember: reminder external id → task id.
        public var taskRefs: [String: UUID] = [:]
        /// Links to remember: list id → project id, for new and reused projects.
        public var projectRefs: [String: UUID] = [:]
        /// Reminders imported before, left as they are.
        public var alreadyImported = 0
        /// Reminders without a title, left out.
        public var untitled = 0

        public init() {}
    }

    /// Server limits (api/src/data/schemas.ts).
    static let maxTitle = 500
    static let maxNotes = 20_000
    static let maxProjectName = 200

    /// How reminders brought over from Siri («ذكرني …», `ReminderBridge` in the app) differ from an import.
    public struct BridgeOptions: Sendable {
        /// The account, so the same reminder becomes the same task on every device (`bridgedTaskId`).
        public var userId: UUID?
        /// Reads «بعد العصر» and other times left in the title when Reminders gave no time.
        public var schedule: PrayerSchedule?

        public init(userId: UUID?, schedule: PrayerSchedule? = nil) {
            self.userId = userId
            self.schedule = schedule
        }
    }

    /// Turns reminders into projects, tasks and time reminders. Lists are imported in the order given;
    /// reminders keep their order within each list. With `bridge`, the tasks go to the inbox (no
    /// projects), their ids come from the reminders (`bridgedTaskId`), and the time words left in a
    /// title are read on the device (`SpokenTime`).
    public static func plan(items: [Item], lists: [List], knownTasks: [String: UUID], knownProjects: [String: UUID],
                            timeZone: TimeZone = .current, now: Date = Date(), firstProjectSortOrder: Double = 0,
                            bridge: BridgeOptions? = nil) -> Plan {
        var plan = Plan()
        let stamp = Milliseconds(now.timeIntervalSince1970 * 1000)
        var nextProjectOrder = firstProjectSortOrder
        var taskOrder: [UUID: Double] = [:]
        let listsById = Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for list in lists {
            if let known = knownProjects[list.id] { plan.projectRefs[list.id] = known }
        }

        for item in items {
            guard let list = listsById[item.listId] else { continue }
            if knownTasks[item.externalId] != nil || plan.taskRefs[item.externalId] != nil {
                plan.alreadyImported += 1
                continue
            }
            let rawTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTitle.isEmpty else {
                plan.untitled += 1
                continue
            }

            // The list's project: the one it became before, or a new one. Siri's reminders go to the inbox.
            let projectId: UUID?
            if bridge != nil {
                projectId = nil
            } else if let existing = plan.projectRefs[list.id] {
                projectId = existing
            } else {
                let name = projectName(list.title)
                let project = ProjectRecord(name: name, sortOrder: nextProjectOrder, createdAt: stamp, updatedAt: stamp)
                nextProjectOrder += 1
                plan.projects.append(project)
                plan.projectRefs[list.id] = project.id
                projectId = project.id
            }

            var title = rawTitle
            var noteLines: [String] = []
            if title.count > maxTitle {
                noteLines.append(title)
                title = String(title.prefix(maxTitle))
            }
            if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                noteLines.append(notes)
            }
            if let url = item.url {
                noteLines.append(url.absoluteString)
            }

            var due = item.due.flatMap { self.due($0, timeZone: timeZone) }
            var prayer: Prayer?
            var prayerOffset: Int?
            // «ذكرني أتصل بأبي بعد العصر»: Reminders keeps the prayer in the title; read it, and a
            // day or time Reminders did not set, unless it already has a time.
            if let bridge, due?.time == nil {
                let spoken = SpokenTime.read(title, now: now, timeZone: timeZone, schedule: bridge.schedule)
                if spoken.hasWhen {
                    title = spoken.title
                    prayer = spoken.duePrayer
                    prayerOffset = spoken.duePrayerOffset
                    if let day = due?.day ?? spoken.dueDate {
                        due = (day: day, time: prayer == nil ? spoken.dueTime : nil)
                    }
                }
            }
            var recurrence: String?
            if let rule = item.repeatRule, !item.isCompleted {
                if rule.isExact {
                    let until = rule.until.map { dayString($0, timeZone: timeZone) }
                    recurrence = Recurrence(frequency: rule.frequency, interval: rule.interval,
                                            weekdays: rule.frequency == .weekly ? rule.weekdays : [],
                                            count: rule.count, until: until).rrule
                } else {
                    noteLines.append("كانت متكررة في تذكيرات أبل بقاعدة لا يدعمها زمام بعد.")
                }
            }

            var notes = noteLines.joined(separator: "\n\n")
            if notes.count > maxNotes { notes = String(notes.prefix(maxNotes)) }

            let orderKey = projectId ?? Self.inboxKey
            let order = taskOrder[orderKey, default: 0]
            taskOrder[orderKey] = order + 1
            let completedAt = item.isCompleted ? Milliseconds((item.completedAt ?? now).timeIntervalSince1970 * 1000) : nil
            let id = bridge.map { bridgedTaskId(userId: $0.userId, externalId: item.externalId) } ?? UUID()
            let task = TaskRecord(id: id, projectId: projectId, title: title, notes: notes.isEmpty ? nil : notes,
                                  status: item.isCompleted ? .done : .todo, priority: priority(fromEventKit: item.priority),
                                  dueDate: due?.day, dueTime: due?.time, duePrayer: prayer,
                                  duePrayerOffset: prayer == nil ? nil : (prayerOffset ?? 0), recurrence: recurrence,
                                  sortOrder: order, completedAt: completedAt, createdAt: stamp, updatedAt: stamp)
            plan.tasks.append(task)
            plan.taskRefs[item.externalId] = task.id

            // Alarms still ahead become time reminders; past ones and those of completed tasks are dropped.
            if !item.isCompleted {
                for alarm in Set(item.alarms).sorted() where alarm > now {
                    plan.reminders.append(ReminderRecord(taskId: task.id, kind: .time,
                                                         at: ReminderPlanner.isoString(from: alarm, timeZone: timeZone),
                                                         createdAt: stamp, updatedAt: stamp))
                }
            }
        }
        return plan
    }

    /// The order key of tasks without a project.
    private static let inboxKey = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// The task a reminder brought over from Siri becomes, the same on every device of the account:
    /// two devices that bring it over before either removes it from Reminders make one task on the
    /// server, not two. Two FNV-1a hashes of the account and the reminder's external identifier,
    /// shaped as a version 8 (custom) UUID.
    public static func bridgedTaskId(userId: UUID?, externalId: String) -> UUID {
        let text = "zimam-bridge|\(userId?.uuidString.lowercased() ?? "local")|\(externalId)"
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }
        let high = fnv(0xCBF2_9CE4_8422_2325)
        let low = fnv(0x84222325CBF29CE4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: high >> (56 - 8 * UInt64(i)))
            bytes[8 + i] = UInt8(truncatingIfNeeded: low >> (56 - 8 * UInt64(i)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// EventKit's priority (1 highest … 9 lowest, 0 none) on Zimam's scale, as Reminders shows it:
    /// 1–4 high, 5 medium, 6–9 low.
    public static func priority(fromEventKit value: Int) -> TaskPriority {
        switch value {
        case 1...4: return .high
        case 5: return .medium
        case 6...9: return .low
        default: return .none
        }
    }

    /// A reminder's due components as the API's local day and "HH:mm". A time with its own zone
    /// is moved to `timeZone`; a floating one (no zone) is read as local, as Reminders shows it.
    public static func due(_ components: DateComponents, timeZone: TimeZone) -> (day: String, time: String?)? {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        var source = components.calendar ?? Calendar(identifier: .gregorian)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone

        if let hour = components.hour {
            source.timeZone = components.timeZone ?? timeZone
            guard let date = source.date(from: DateComponents(year: year, month: month, day: day, hour: hour,
                                                              minute: components.minute ?? 0)) else { return nil }
            let local = gregorian.dateComponents([.hour, .minute], from: date)
            let time = String(format: "%02d:%02d", local.hour ?? 0, local.minute ?? 0)
            return (dayString(date, timeZone: timeZone), time)
        }
        if source.identifier == .gregorian {
            return (String(format: "%04d-%02d-%02d", year, month, day), nil)
        }
        // A day in another calendar: noon that day, written as the Gregorian day.
        source.timeZone = timeZone
        guard let date = source.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return nil }
        return (dayString(date, timeZone: timeZone), nil)
    }

    static func projectName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "تذكيرات" }
        return trimmed.count > maxProjectName ? String(trimmed.prefix(maxProjectName)) : trimmed
    }

    static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// «أُضيفت ١٢ مهمة في مشروعين.» and what was left out, for the screen after an import.
    public static func summary(_ plan: Plan, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        var lines: [String] = []
        let tasks = plan.tasks.count
        let number = { (n: Int) in n.formatted(.number.locale(locale)) }
        if tasks == 0 {
            lines.append(plan.alreadyImported > 0 ? "لا جديد: كل التذكيرات المختارة مستوردة من قبل." : "لا تذكيرات في القوائم المختارة.")
        } else {
            let count: String
            switch tasks {
            case 1: count = "أُضيفت مهمة واحدة"
            case 2: count = "أُضيفت مهمتان"
            case 3...10: count = "أُضيفت \(number(tasks)) مهام"
            default: count = "أُضيفت \(number(tasks)) مهمة"
            }
            lines.append(count + ".")
            if plan.alreadyImported > 0 {
                lines.append("و\(number(plan.alreadyImported)) مستوردة من قبل فلم تتكرر.")
            }
        }
        if plan.untitled > 0 {
            lines.append("وتُرك ما لا عنوان له: \(number(plan.untitled)).")
        }
        return lines.joined(separator: " ")
    }
}
