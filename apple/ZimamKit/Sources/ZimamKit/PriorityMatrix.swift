import Foundation

/// The four quadrants of «المصفوفة» (an Eisenhower matrix), shared by the app and the widgets.
///
/// - important: priority medium or high (`TaskPriority.rawValue >= 2`).
/// - urgent: a due day on or before tomorrow, overdue included, counted in the user's time zone
///   (the `calendar` passed in). A task without a due day is never urgent.
///
/// Done and deleted tasks belong to no quadrant; `PriorityMatrix.group` leaves them out.
public enum PriorityQuadrant: String, CaseIterable, Sendable, Hashable, Identifiable {
    case urgentImportant, important, urgent, someday

    public var id: String { rawValue }

    /// «مهم وعاجل», «مهم», «عاجل», «يوماً ما».
    public var title: String {
        switch self {
        case .urgentImportant: "مهم وعاجل"
        case .important: "مهم"
        case .urgent: "عاجل"
        case .someday: "يوماً ما"
        }
    }

    public var isImportant: Bool { self == .urgentImportant || self == .important }
    public var isUrgent: Bool { self == .urgentImportant || self == .urgent }

    public init(important: Bool, urgent: Bool) {
        switch (important, urgent) {
        case (true, true): self = .urgentImportant
        case (true, false): self = .important
        case (false, true): self = .urgent
        case (false, false): self = .someday
        }
    }

    /// The quadrant of an open task. `today` is now; `calendar` gives the user's time zone.
    public static func quadrant(priority: TaskPriority, dueDate: String?, today: Date = Date(),
                                calendar: Calendar) -> PriorityQuadrant {
        PriorityQuadrant(important: PriorityMatrix.isImportant(priority),
                         urgent: PriorityMatrix.isUrgent(dueDate: dueDate, today: today, calendar: calendar))
    }
}

/// Grouping tasks into quadrants, and what moving a task between quadrants changes.
public enum PriorityMatrix {
    /// Medium or high.
    public static func isImportant(_ priority: TaskPriority) -> Bool {
        priority.rawValue >= TaskPriority.medium.rawValue
    }

    /// Due on or before tomorrow in `calendar`'s time zone, overdue included.
    public static func isUrgent(dueDate: String?, today: Date = Date(), calendar: Calendar) -> Bool {
        guard let dueDate, isDay(dueDate), let tomorrow = day(1, after: today, calendar: calendar) else { return false }
        // API days ("2026-10-15") compare as text.
        return dueDate <= tomorrow
    }

    /// The API day `offset` days after `date`'s day, in `calendar`'s time zone: "2026-10-16".
    public static func day(_ offset: Int, after date: Date, calendar: Calendar) -> String? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        guard let moved = gregorian.date(byAdding: .day, value: offset, to: gregorian.startOfDay(for: date)) else { return nil }
        let c = gregorian.dateComponents([.year, .month, .day], from: moved)
        guard let year = c.year, let month = c.month, let dayOfMonth = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
    }

    /// Items by quadrant, each in the order given. Every quadrant is present, possibly empty.
    /// `isOpen` leaves out done (and deleted) items.
    public static func group<Item>(_ items: [Item], today: Date = Date(), calendar: Calendar,
                                   isOpen: (Item) -> Bool, priority: (Item) -> TaskPriority,
                                   dueDate: (Item) -> String?) -> [PriorityQuadrant: [Item]] {
        var result = Dictionary(uniqueKeysWithValues: PriorityQuadrant.allCases.map { ($0, [Item]()) })
        for item in items where isOpen(item) {
            let quadrant = PriorityQuadrant.quadrant(priority: priority(item), dueDate: dueDate(item), today: today,
                                                     calendar: calendar)
            result[quadrant, default: []].append(item)
        }
        return result
    }

    /// Records by quadrant; done tasks are left out.
    public static func group(_ tasks: [TaskRecord], today: Date = Date(), calendar: Calendar) -> [PriorityQuadrant: [TaskRecord]] {
        group(tasks, today: today, calendar: calendar, isOpen: { $0.status != .done }, priority: \.priority,
              dueDate: \.dueDate)
    }

    /// How many open items each quadrant has.
    public static func counts<Item>(_ grouped: [PriorityQuadrant: [Item]]) -> [PriorityQuadrant: Int] {
        grouped.mapValues(\.count)
    }

    // MARK: Moving between quadrants

    /// What dropping a task on another quadrant does.
    public enum Move: Equatable, Sendable {
        /// Already there: nothing changes.
        case unchanged
        /// The task's new priority and due day.
        case moved(priority: TaskPriority, dueDate: String?)
        /// Leaving «عاجل» would clear a due day that carries more than the day itself.
        case refused
    }

    /// The rules for dragging a task between quadrants. Only what the target needs changes:
    ///
    /// 1. Into an important quadrant: a priority below medium becomes medium; a medium or high
    ///    priority stays.
    /// 2. Out of the important ones: a medium or high priority becomes low; a lower one stays.
    /// 3. Into an urgent quadrant: a task that is not urgent yet becomes due today. Its time or
    ///    prayer stays with it, as when a task moves to another day. One that is already urgent
    ///    (overdue, today or tomorrow) keeps its day.
    /// 4. Out of the urgent ones: the due day is cleared, but only when that is safe, meaning the
    ///    task has nothing else tied to the day (`isAnchored`: a time, a prayer, a repeat, a start
    ///    day or a reminder). Otherwise the move is refused, and the user changes the date in the
    ///    task's details, where they see what it affects.
    public static func move(priority: TaskPriority, dueDate: String?, isAnchored: Bool, to target: PriorityQuadrant,
                            today: Date = Date(), calendar: Calendar) -> Move {
        let current = PriorityQuadrant.quadrant(priority: priority, dueDate: dueDate, today: today, calendar: calendar)
        guard current != target else { return .unchanged }

        var newPriority = priority
        if target.isImportant && !isImportant(priority) { newPriority = .medium }
        if !target.isImportant && isImportant(priority) { newPriority = .low }

        var newDue = dueDate
        if target.isUrgent && !current.isUrgent {
            newDue = day(0, after: today, calendar: calendar)
        }
        if !target.isUrgent && current.isUrgent {
            if isAnchored { return .refused }
            newDue = nil
        }
        return .moved(priority: newPriority, dueDate: newDue)
    }

    private static func isDay(_ text: String) -> Bool {
        text.count == 10 && text.split(separator: "-").count == 3
    }
}
