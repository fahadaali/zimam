import Foundation

/// One Apple Calendar event occurrence (`EKEvent`) as plain values. The app reads EventKit on the
/// device and turns each occurrence into this, both to show events over Zimam's calendar (read only)
/// and to import them as tasks (`AppleCalendarImport`). A recurring event comes as one value per
/// occurrence, each with the series' `externalId` and its own `occurrenceDate`.
public struct AppleCalendarEvent: Equatable, Identifiable, Sendable {
    /// `calendarItemExternalIdentifier` (the same on every device, and for every occurrence of a
    /// series), or the local identifier when there is none.
    public var externalId: String
    /// `eventIdentifier`, to find the event again on this device («فتح في التقويم»).
    public var eventId: String?
    /// The `EKCalendar`'s `calendarIdentifier`.
    public var calendarId: String
    public var title: String
    public var notes: String?
    public var location: String?
    public var url: URL?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The occurrence's original start (`occurrenceDate`): stays the same when one occurrence of a
    /// series is moved, so it keys the occurrence.
    public var occurrenceDate: Date
    /// The event repeats (`hasRecurrenceRules`), whether or not `repeatRule` could be read.
    public var isRecurring: Bool
    /// The series' rule, when there is one; `isExact` false when Zimam cannot express it.
    public var repeatRule: AppleRemindersImport.Repeat?
    /// One occurrence of a series edited on its own.
    public var isDetached: Bool

    public init(externalId: String, eventId: String? = nil, calendarId: String, title: String, notes: String? = nil,
                location: String? = nil, url: URL? = nil, start: Date, end: Date, isAllDay: Bool = false,
                occurrenceDate: Date? = nil, isRecurring: Bool? = nil, repeatRule: AppleRemindersImport.Repeat? = nil,
                isDetached: Bool = false) {
        self.externalId = externalId
        self.eventId = eventId
        self.calendarId = calendarId
        self.title = title
        self.notes = notes
        self.location = location
        self.url = url
        self.start = start
        self.end = max(start, end)
        self.isAllDay = isAllDay
        self.occurrenceDate = occurrenceDate ?? start
        self.isRecurring = isRecurring ?? (repeatRule != nil)
        self.repeatRule = repeatRule
        self.isDetached = isDetached
    }

    /// Unique per occurrence on this device.
    public var id: String { "\(externalId)|\(Int64(occurrenceDate.timeIntervalSince1970))" }

    /// The days the event covers in `timeZone`. An end at midnight belongs to the day before, so a
    /// 10:00–11:00 event and an all-day event (EventKit ends it at 23:59:59) are one day.
    public func span(timeZone: TimeZone) -> DaySpan {
        let startDay = AppleRemindersImport.dayString(start, timeZone: timeZone)
        let lastInstant = end > start ? end.addingTimeInterval(-1) : start
        let endDay = AppleRemindersImport.dayString(lastInstant, timeZone: timeZone)
        return DaySpan(start: startDay, end: max(startDay, endDay))
    }

    /// The day this occurrence was planned on, for keys: `occurrenceDate` in `timeZone`.
    public func occurrenceDay(timeZone: TimeZone) -> String {
        AppleRemindersImport.dayString(occurrenceDate, timeZone: timeZone)
    }

    /// What a task made from this occurrence remembers it by: the event for a single event,
    /// the event and the occurrence's day ("id#2026-10-15") for one occurrence of a series.
    public func importKey(timeZone: TimeZone) -> String {
        isRecurring ? AppleCalendarImport.occurrenceKey(externalId, day: occurrenceDay(timeZone: timeZone)) : externalId
    }

    /// Ordering within a day: events that cover the whole day (all-day or spanning days) first,
    /// then by start time, then by title.
    public static func dayOrder(_ a: AppleCalendarEvent, _ b: AppleCalendarEvent, timeZone: TimeZone) -> Bool {
        let aWhole = a.isAllDay || a.span(timeZone: timeZone).isMultiDay
        let bWhole = b.isAllDay || b.span(timeZone: timeZone).isMultiDay
        if aWhole != bWhole { return aWhole }
        if a.start != b.start { return a.start < b.start }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    // MARK: As a task

    /// The task fields an occurrence becomes, without recurrence. Nil when it has no title.
    public struct TaskFields: Equatable, Sendable {
        public var title: String
        public var notes: String?
        public var dueDate: String
        /// The first day of an event that spans days; nil for one day.
        public var startDate: String?
        /// "HH:mm" for a timed one-day event.
        public var dueTime: String?
    }

    /// Title (500 characters at most, the rest kept in the notes), notes with the location and
    /// link, and the day: a one-day event is due on its day, at its start time unless all-day;
    /// an event that spans days starts on its first day and is due on its last, without a time.
    public func taskFields(timeZone: TimeZone) -> TaskFields? {
        let trimmedTitle = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        var taskTitle = trimmedTitle
        var lines: [String] = []
        if ServerText.exceeds(taskTitle, ServerText.maxTitle) {
            lines.append(taskTitle)
            taskTitle = ServerText.clip(taskTitle, to: ServerText.maxTitle)
        }
        if let place = self.location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            lines.append("المكان: \(place)")
        }
        if let text = self.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines.append(text)
        }
        if let link = self.url {
            lines.append(link.absoluteString)
        }
        var taskNotes = lines.joined(separator: "\n\n")
        taskNotes = ServerText.clip(taskNotes, to: ServerText.maxNotes)

        let days = self.span(timeZone: timeZone)
        var time: String?
        if !isAllDay && !days.isMultiDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute], from: start)
            time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        return TaskFields(title: taskTitle, notes: taskNotes.isEmpty ? nil : taskNotes, dueDate: days.end,
                          startDate: days.startDate, dueTime: time)
    }
}

/// Apple Calendar events imported as tasks on the device. Each calendar becomes a project; each
/// event a task. A series whose rule Zimam can express becomes one repeating task from its first
/// occurrence in the window; any other series becomes one task per occurrence in the window.
///
/// A re-import skips what was imported before, as with Reminders: the caller remembers each key
/// with the task it became (`Plan.taskRefs`) and each calendar with its project (`Plan.projectRefs`).
/// Keys are the event's `calendarItemExternalIdentifier` for a single event or a repeating task,
/// and "<identifier>#<day>" (`occurrenceKey`) for an occurrence imported on its own.
public enum AppleCalendarImport {
    /// The id the import screen uses for this source; the server does not know it.
    public static let sourceId = "apple-calendar"

    /// A calendar (an `EKCalendar` of type event).
    public struct CalendarRef: Equatable, Hashable, Identifiable, Sendable {
        /// `calendarIdentifier`.
        public var id: String
        public var title: String
        /// The account it belongs to («iCloud»، «Gmail»…), to tell same-named calendars apart.
        public var sourceTitle: String

        public init(id: String, title: String, sourceTitle: String = "") {
            self.id = id
            self.title = title
            self.sourceTitle = sourceTitle
        }
    }

    /// What an import adds.
    public struct Plan: Equatable, Sendable {
        public var projects: [ProjectRecord] = []
        public var tasks: [TaskRecord] = []
        /// New links to remember: event key → task id.
        public var taskRefs: [String: UUID] = [:]
        /// Links to remember: calendar id → project id, for new and reused projects.
        public var projectRefs: [String: UUID] = [:]
        /// Events (a series counts once) imported before, left as they are.
        public var alreadyImported = 0
        /// Events without a title, left out.
        public var untitled = 0
        /// Series whose rule Zimam cannot express, imported occurrence by occurrence.
        public var expandedSeries = 0

        public init() {}
    }

    /// The key of one occurrence of a series imported on its own.
    public static func occurrenceKey(_ externalId: String, day: String) -> String {
        "\(externalId)#\(day)"
    }

    /// From the start of today to the same day `months` months later, in `timeZone`.
    public static func window(months: Int, now: Date = Date(), timeZone: TimeZone = .current) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .month, value: max(1, months), to: start) ?? start.addingTimeInterval(30 * 86_400)
        return (start, end)
    }

    /// The RRULE of a series whose first occurrence in the window is on `anchorDay`. `COUNT` in
    /// EventKit counts from the series' first occurrence (`seriesStartDay`), and in Zimam the
    /// occurrences left from the task's own: the ones before `anchorDay` are taken off. Nil when the
    /// rule is not exact, or has a count without a known series start, or no occurrence is left.
    public static func recurrence(_ rule: AppleRemindersImport.Repeat, anchorDay: String, seriesStartDay: String?,
                                  timeZone: TimeZone) -> String? {
        guard rule.isExact else { return nil }
        let until = rule.until.map { AppleRemindersImport.dayString($0, timeZone: timeZone) }
        let weekdays = rule.frequency == .weekly ? rule.weekdays : []
        var count = rule.count
        // The series' own day of the month, so a short month on the way does not move the
        // occurrences after it (`Recurrence`).
        let seriesMonthDay = seriesStartDay.flatMap { Int($0.suffix(2)) }
        let seriesMonth = seriesStartDay.flatMap { Int($0.dropFirst(5).prefix(2)) }
        if let total = rule.count {
            guard let first = seriesStartDay, first <= anchorDay else { return nil }
            let stepper = Recurrence(frequency: rule.frequency, interval: rule.interval, weekdays: weekdays,
                                     monthDay: seriesMonthDay, month: seriesMonth)
            var day = first
            var before = 0
            while day < anchorDay {
                guard let next = stepper.nextDay(after: day, timeZone: timeZone) else { return nil }
                before += 1
                day = next
                if before >= total { return nil }
            }
            count = total - before
        }
        // An anchor moved earlier by a short month (the series' 31st on a 30th) carries that day.
        let moved = seriesStartDay.map { $0.suffix(2) != anchorDay.suffix(2) } ?? false
        return Recurrence(frequency: rule.frequency, interval: rule.interval, weekdays: weekdays,
                          count: count, until: until,
                          monthDay: moved ? seriesMonthDay : nil, month: moved ? seriesMonth : nil).rrule
    }

    /// Turns events into projects and tasks. Calendars are imported in the order given, events by
    /// start within each calendar. `seriesStarts` gives each counted series' first occurrence
    /// (external id → its start), to carry the right `COUNT`.
    public static func plan(events: [AppleCalendarEvent], calendars: [CalendarRef], knownTasks: [String: UUID],
                            knownProjects: [String: UUID], seriesStarts: [String: Date] = [:],
                            timeZone: TimeZone = .current, now: Date = Date(), firstProjectSortOrder: Double = 0) -> Plan {
        var plan = Plan()
        let stamp = Milliseconds(now.timeIntervalSince1970 * 1000)
        var nextProjectOrder = firstProjectSortOrder
        var taskOrder: [UUID: Double] = [:]
        let calendarsById = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for calendar in calendars {
            if let known = knownProjects[calendar.id] { plan.projectRefs[calendar.id] = known }
        }
        func isKnown(_ key: String) -> Bool { knownTasks[key] != nil || plan.taskRefs[key] != nil }

        // Calendar order, then start: what is added reads in time order inside each project.
        let calendarIndex = Dictionary(calendars.enumerated().map { pair in (pair.element.id, pair.offset) }, uniquingKeysWith: { a, _ in a })
        let chosen = events
            .filter { calendarsById[$0.calendarId] != nil }
            .sorted { a, b in
                let ia = calendarIndex[a.calendarId] ?? 0
                let ib = calendarIndex[b.calendarId] ?? 0
                if ia != ib { return ia < ib }
                return a.start < b.start
            }

        // Each series' occurrences in order, grouped once rather than filtered per series.
        let bySeries = Dictionary(grouping: chosen, by: \.externalId)

        // Each series is decided once, at its first occurrence here.
        var seriesSeen: Set<String> = []
        var expandedSeriesIds: Set<String> = []
        var expandedAdded: Set<String> = []

        func add(_ fields: AppleCalendarEvent.TaskFields, recurrence: String?, calendar: CalendarRef, key: String) {
            let projectId: UUID
            if let existing = plan.projectRefs[calendar.id] {
                projectId = existing
            } else {
                let project = ProjectRecord(name: projectName(calendar.title), sortOrder: nextProjectOrder,
                                            createdAt: stamp, updatedAt: stamp)
                nextProjectOrder += 1
                plan.projects.append(project)
                plan.projectRefs[calendar.id] = project.id
                projectId = project.id
            }
            let order = taskOrder[projectId, default: 0]
            taskOrder[projectId] = order + 1
            let task = TaskRecord(projectId: projectId, title: fields.title, notes: fields.notes,
                                  dueDate: fields.dueDate, startDate: fields.startDate, dueTime: fields.dueTime,
                                  recurrence: recurrence, sortOrder: order, createdAt: stamp, updatedAt: stamp)
            plan.tasks.append(task)
            plan.taskRefs[key] = task.id
        }

        for event in chosen {
            guard let calendar = calendarsById[event.calendarId] else { continue }
            if !event.isRecurring {
                if isKnown(event.externalId) {
                    plan.alreadyImported += 1
                    continue
                }
                guard let fields = event.taskFields(timeZone: timeZone) else {
                    plan.untitled += 1
                    continue
                }
                add(fields, recurrence: nil, calendar: calendar, key: event.externalId)
                continue
            }

            let series = event.externalId
            if seriesSeen.insert(series).inserted {
                // First occurrence of the series in the window: one repeating task when the rule allows.
                if isKnown(series) {
                    plan.alreadyImported += 1
                    continue
                }
                let occurrences = bySeries[series] ?? []
                // A moved occurrence would put the series on the wrong day: anchor on one planned as the rule says.
                let anchor = occurrences.first(where: { !$0.isDetached }) ?? event
                let anchorSpan = anchor.span(timeZone: timeZone)
                let seriesStartDay = seriesStarts[series].map { AppleRemindersImport.dayString($0, timeZone: timeZone) }
                // Zimam repeats from the due day; for an event that spans days that is its last day,
                // which falls on other weekdays than the ones the rule names.
                if let rule = anchor.repeatRule, !(anchorSpan.isMultiDay && !rule.weekdays.isEmpty),
                   let rrule = recurrence(rule, anchorDay: anchorSpan.start, seriesStartDay: seriesStartDay,
                                          timeZone: timeZone) {
                    guard let fields = anchor.taskFields(timeZone: timeZone) else {
                        plan.untitled += 1
                        continue
                    }
                    add(fields, recurrence: rrule, calendar: calendar, key: series)
                    continue
                }
                expandedSeriesIds.insert(series)
            } else if !expandedSeriesIds.contains(series) {
                // Covered by the series' repeating task, imported now or before.
                continue
            }

            // An occurrence on its own.
            if isKnown(series) { continue }
            let key = event.importKey(timeZone: timeZone)
            if isKnown(key) {
                plan.alreadyImported += 1
                continue
            }
            guard let fields = event.taskFields(timeZone: timeZone) else {
                plan.untitled += 1
                continue
            }
            add(fields, recurrence: nil, calendar: calendar, key: key)
            expandedAdded.insert(series)
        }
        plan.expandedSeries = expandedAdded.count
        return plan
    }

    static func projectName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "تقويم" }
        return ServerText.clip(trimmed, to: ServerText.maxName)
    }

    /// «أُضيفت ١٢ مهمة.» and what was left out, for the screen after an import.
    public static func summary(_ plan: Plan, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        var lines: [String] = []
        let tasks = plan.tasks.count
        let number = { (n: Int) in n.formatted(.number.locale(locale)) }
        if tasks == 0 {
            lines.append(plan.alreadyImported > 0
                         ? "لا جديد: كل الأحداث المختارة مستوردة من قبل."
                         : "لا أحداث في التقاويم المختارة خلال هذه المدة.")
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
        if plan.expandedSeries > 0 {
            lines.append("وما تكرر بقاعدة لا يدعمها زمام استُورد كل موعد منه مهمةً مستقلة.")
        }
        if plan.untitled > 0 {
            lines.append("وتُرك ما لا عنوان له: \(number(plan.untitled)).")
        }
        return lines.joined(separator: " ")
    }
}
