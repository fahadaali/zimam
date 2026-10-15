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

    /// Turns reminders into projects, tasks and time reminders. Lists are imported in the order given;
    /// reminders keep their order within each list.
    public static func plan(items: [Item], lists: [List], knownTasks: [String: UUID], knownProjects: [String: UUID],
                            timeZone: TimeZone = .current, now: Date = Date(), firstProjectSortOrder: Double = 0) -> Plan {
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

            // The list's project: the one it became before, or a new one.
            let projectId: UUID
            if let existing = plan.projectRefs[list.id] {
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

            let due = item.due.flatMap { self.due($0, timeZone: timeZone) }
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

            let order = taskOrder[projectId, default: 0]
            taskOrder[projectId] = order + 1
            let completedAt = item.isCompleted ? Milliseconds((item.completedAt ?? now).timeIntervalSince1970 * 1000) : nil
            let task = TaskRecord(projectId: projectId, title: title, notes: notes.isEmpty ? nil : notes,
                                  status: item.isCompleted ? .done : .todo, priority: priority(fromEventKit: item.priority),
                                  dueDate: due?.day, dueTime: due?.time, recurrence: recurrence, sortOrder: order,
                                  completedAt: completedAt, createdAt: stamp, updatedAt: stamp)
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
