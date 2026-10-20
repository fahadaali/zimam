import Foundation
import SwiftData
import SwiftUI
import ZimamKit

// What the home-screen widget family shares. This file: the open task as the widgets show it, the
// start…due span of a task, the priority quadrant, and the words for a task's priority and time.
// The rest: WidgetSnapshot.swift (the store read once per timeline), WidgetCalendarChoice.swift,
// WidgetTone.swift (colors for each rendering mode and the sizes), WidgetFrame.swift (the root
// modifiers), WidgetPieces.swift and WidgetTaskChip.swift (the small pieces every widget draws).

// MARK: Data

/// One open task as the calendar, list and matrix widgets show it.
struct WidgetItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let priority: TaskPriority
    let isTopLevel: Bool
    /// The first day it covers; its due day unless it spans several (`WidgetTaskSpan`).
    let startDay: String?
    let dueDay: String?
    let prayer: Prayer?
    let prayerOffset: Int?
    let sortOrder: Double
    /// When it falls on its due day, if known: its time, or its prayer's time where the place is known.
    let time: Date?
    /// Minutes after midnight on its due day, for ordering (prayer tasks without a place get an
    /// approximate minute so they still sort among the timed ones).
    let minuteOfDay: Int?

    /// Its place on the calendar widgets, when it has a due day.
    var dated: DatedTask? {
        guard let dueDay else { return nil }
        return DatedTask(id: id, startDay: startDay, endDay: dueDay, minuteOfDay: minuteOfDay, sortOrder: sortOrder)
    }

    var isSpan: Bool { dated?.isSpan ?? false }
}

/// The days a task covers on the calendar widgets.
///
/// A task covers startDate…dueDate, or its due day alone without a start (a start after the due
/// day is ignored by `DatedTask`).
enum WidgetTaskSpan {
    static func span(for task: TaskItem) -> (start: String, end: String)? {
        guard let due = task.dueDate else { return nil }
        return (task.startDate ?? due, due)
    }
}

/// The four quadrants of the priority matrix.
///
/// The widget's face of the shared `ZimamKit.PriorityQuadrant`, so the matrix screen and the
/// widget agree: important := medium or high priority; urgent := due on or before tomorrow
/// (overdue included), in the user's time zone. Done and deleted tasks are not classified.
enum WidgetQuadrant: String, CaseIterable {
    case importantUrgent, important, urgent, someday

    static func classify(priority: TaskPriority, dueDay: String?, tomorrow: String) -> WidgetQuadrant {
        let shared = ZimamKit.PriorityQuadrant(important: ZimamKit.PriorityMatrix.isImportant(priority),
                                               urgent: dueDay.map { $0 <= tomorrow } ?? false)
        switch shared {
        case .urgentImportant: return .importantUrgent
        case .important: return .important
        case .urgent: return .urgent
        case .someday: return .someday
        }
    }

    var title: String {
        switch self {
        case .importantUrgent: "مهم وعاجل"
        case .important: "مهم"
        case .urgent: "عاجل"
        case .someday: "يوماً ما"
        }
    }

    var symbol: String {
        switch self {
        case .importantUrgent: "flame"
        case .important: "star"
        case .urgent: "bolt"
        case .someday: "tray"
        }
    }

    /// The quadrant's color: the priority tokens, from the most pressing down; neutral for «يوماً ما».
    var color: Color {
        switch self {
        case .importantUrgent: ZimamColor.quadrantUrgentImportant
        case .important: ZimamColor.quadrantImportant
        case .urgent: ZimamColor.quadrantUrgent
        case .someday: ZimamColor.quadrantSomeday
        }
    }
}

/// Arabic text for a priority, so it is never told by color alone.
func priorityLabel(_ priority: TaskPriority) -> String? {
    switch priority {
    case .high: "أولوية عالية"
    case .medium: "أولوية متوسطة"
    case .low: "أولوية منخفضة"
    case .none: nil
    }
}

/// When a task falls, as a list row shows it: its prayer phrase, its time today, a word for a
/// nearby day, or both calendars further out; «متأخرة» once its day has gone.
func widgetWhenText(_ item: WidgetItem, snapshot: WidgetSnapshot, now: Date) -> String? {
    guard let due = item.dueDay else { return nil }
    let formatter = snapshot.formatter
    if due < snapshot.today { return "متأخرة" }
    if let prayer = item.prayer {
        let phrase = PrayerPhrase.text(prayer, offsetMinutes: item.prayerOffset, locale: formatter.locale)
        if due == snapshot.today { return phrase }
        guard let date = formatter.date(fromDay: due) else { return phrase }
        return "\(formatter.label(for: date, now: now))، \(phrase)"
    }
    if due == snapshot.today, let time = item.time {
        return formatter.time(time)
    }
    guard let date = formatter.date(fromDay: due) else { return nil }
    let label = formatter.label(for: date, now: now)
    if let time = item.time { return "\(label)، \(formatter.time(time))" }
    return label
}

/// Whether a row's time should read as late: overdue, or today's time already gone.
func widgetIsLate(_ item: WidgetItem, snapshot: WidgetSnapshot, now: Date) -> Bool {
    guard let due = item.dueDay else { return false }
    if due < snapshot.today { return true }
    if due == snapshot.today, let time = item.time { return time <= now }
    return false
}
