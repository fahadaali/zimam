import AppIntents
import Foundation
import SwiftData
import SwiftUI
import WidgetKit
import ZimamKit

// What the home-screen widget family shares: the store read once per timeline, the start…due
// span of a task, the temporary priority quadrant, the calendar choice, colors for each rendering
// mode, and the small pieces every widget draws (completion circle, chips, badges).

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

/// The store as the widgets read it, once per timeline.
struct WidgetSnapshot {
    let isSignedIn: Bool
    let calendar: CalendarKind
    /// The week's first column, 1 = Sunday (as `Calendar.firstWeekday`).
    let firstWeekday: Int
    let today: String
    let tomorrow: String
    let nextMidnight: Date
    /// Open tasks: not done and not deleted, with a date or without.
    let items: [WidgetItem]

    var formatter: DualDateFormatter {
        DualDateFormatter(primary: calendar, locale: ZimamLocale.current)
    }

    func grid(_ kind: CalendarKind? = nil) -> CalendarGrid {
        CalendarGrid(kind: kind ?? calendar, firstWeekday: firstWeekday, timeZone: .current)
    }

    /// Open top-level tasks with a due day, as the calendar widgets place them.
    var calendarItems: [WidgetItem] {
        items.filter { $0.isTopLevel && $0.dueDay != nil }
    }

    func item(_ id: UUID) -> WidgetItem? {
        items.first { $0.id == id }
    }

    /// Today's task times still ahead: moments a widget shows something new.
    func timesAhead(of now: Date) -> [Date] {
        let times = Set(items.compactMap { item -> Date? in
            guard item.dueDay == today, let time = item.time, time > now, time < nextMidnight else { return nil }
            return time
        })
        return Array(times.sorted().prefix(12))
    }

    /// An entry now, one at each of today's task times ahead when `atTaskTimes`; the timeline
    /// ends at midnight. The app also reloads the widgets after every change.
    func entryDates(now: Date, atTaskTimes: Bool) -> [Date] {
        atTaskTimes ? [now] + timesAhead(of: now) : [now]
    }

    // MARK: Reading the store

    static func load(now: Date) -> WidgetSnapshot {
        let days = DayContext(now: now)
        guard let user = SharedSettings.user() else {
            return WidgetSnapshot(isSignedIn: false, calendar: .hijri, firstWeekday: Calendar.current.firstWeekday,
                                  today: days.today, tomorrow: days.tomorrow, nextMidnight: days.nextMidnight, items: [])
        }
        let schedule = SharedSettings.prayerSchedule()
        let context = ModelContext(ZimamStore.shared)
        let all = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let items = all.filter { !$0.isDone }.map { task -> WidgetItem in
            let span = WidgetTaskSpan.span(for: task)
            let time = task.dueDate.flatMap { days.time(dueDay: $0, dueTime: task.dueTime, prayer: task.duePrayer,
                                                        offset: task.duePrayerOffset, schedule: schedule) }
            return WidgetItem(id: task.id, title: task.title, priority: task.priority, isTopLevel: task.parentId == nil,
                              startDay: span?.start, dueDay: span?.end ?? task.dueDate, prayer: task.duePrayer,
                              prayerOffset: task.duePrayerOffset, sortOrder: task.sortOrder, time: time,
                              minuteOfDay: days.minute(of: time, prayer: task.duePrayer, offset: task.duePrayerOffset))
        }
        let start = user.settings.weekStart
        return WidgetSnapshot(isSignedIn: true, calendar: user.settings.calendar,
                              firstWeekday: (0...6).contains(start) ? start + 1 : Calendar.current.firstWeekday,
                              today: days.today, tomorrow: days.tomorrow, nextMidnight: days.nextMidnight, items: items)
    }

    /// For the widget gallery and placeholders: a believable week around today.
    static func placeholder(now: Date) -> WidgetSnapshot {
        let days = DayContext(now: now)
        func item(_ title: String, _ priority: TaskPriority, in offset: Int?, until end: Int? = nil,
                  at clock: String? = nil, prayer: Prayer? = nil, after minutes: Int? = nil) -> WidgetItem {
            let due = offset.map { days.day(in: end ?? $0) }
            let start = offset.map { days.day(in: $0) }
            let time = due.flatMap { days.time(dueDay: $0, dueTime: clock, prayer: prayer, offset: minutes, schedule: nil) }
            return WidgetItem(id: UUID(), title: title, priority: priority, isTopLevel: true, startDay: start, dueDay: due,
                              prayer: prayer, prayerOffset: minutes, sortOrder: 0, time: time,
                              minuteOfDay: days.minute(of: time, prayer: prayer, offset: minutes))
        }
        let items = [
            item("تجديد الاشتراك", .high, in: -1),
            item("مراجعة العقد", .high, in: 0, at: "10:00"),
            item("الاتصال بالوالدة", .medium, in: 0, prayer: .asr, after: 20),
            item("قراءة ورد اليوم", .none, in: 0, prayer: .fajr),
            item("اجتماع الفريق", .low, in: 1, at: "09:30"),
            item("رحلة إلى جدة", .low, in: 1, until: 3),
            item("شراء هدية", .medium, in: 2, at: "18:00"),
            item("خطة الأسبوع", .high, in: 5),
            item("حجز موعد الطبيب", .none, in: 8, at: "16:00"),
            item("ترتيب المكتبة", .none, in: nil),
            item("قراءة كتاب", .medium, in: nil),
        ]
        return WidgetSnapshot(isSignedIn: true, calendar: .hijri, firstWeekday: Calendar.current.firstWeekday,
                              today: days.today, tomorrow: days.tomorrow, nextMidnight: days.nextMidnight, items: items)
    }
}

/// Today, tomorrow and midnight in the device's time zone, and task times on a day.
private struct DayContext {
    let now: Date
    let gregorian: Calendar
    let formatter = DualDateFormatter()
    let today: String
    let tomorrow: String
    let nextMidnight: Date

    init(now: Date) {
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        gregorian = calendar
        let start = calendar.startOfDay(for: now)
        nextMidnight = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
        today = DualDateFormatter().dayString(from: now)
        tomorrow = DualDateFormatter().dayString(from: nextMidnight.addingTimeInterval(3600))
    }

    func day(in offset: Int) -> String {
        formatter.dayString(from: gregorian.date(byAdding: .day, value: offset, to: now) ?? now)
    }

    /// Its clock time on the due day, or its prayer's time there when the place is known.
    func time(dueDay: String, dueTime: String?, prayer: Prayer?, offset: Int?, schedule: PrayerSchedule?) -> Date? {
        if let prayer {
            guard let schedule, let day = formatter.date(fromDay: dueDay) else { return nil }
            return schedule.time(of: prayer, on: day.addingTimeInterval(12 * 3600), offsetMinutes: offset ?? 0)
        }
        return GlanceSnapshot.time(dueTime, onDay: dueDay)
    }

    func minute(of time: Date?, prayer: Prayer?, offset: Int?) -> Int? {
        if let time {
            let parts = gregorian.dateComponents([.hour, .minute], from: time)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        guard let prayer else { return nil }
        // Without a place: roughly where each prayer falls, only to keep the order of the day.
        let approximate: [Prayer: Int] = [.fajr: 300, .dhuhr: 720, .asr: 930, .maghrib: 1080, .isha: 1200]
        return (approximate[prayer] ?? 0) + (offset ?? 0)
    }
}

// MARK: Calendar choice

/// Which calendar a configurable widget uses: the user's own (settings), Hijri or Gregorian.
enum WidgetCalendarChoice: String, AppEnum {
    case automatic, hijri, gregorian

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "التقويم"
    static var caseDisplayRepresentations: [WidgetCalendarChoice: DisplayRepresentation] = [
        .automatic: "تقويمك في الإعدادات",
        .hijri: "الهجري",
        .gregorian: "الميلادي",
    ]

    func kind(default fallback: CalendarKind) -> CalendarKind {
        switch self {
        case .automatic: fallback
        case .hijri: .hijri
        case .gregorian: .gregorian
        }
    }
}

// MARK: Rendering modes

/// Colors by rendering mode. In full color (the home screen, StandBy by day, the Mac desktop in
/// front) the Zimam tokens. Tinted home screens draw widgets "accented" and StandBy at night and
/// the Mac desktop behind windows draw them "vibrant": colors become one tone, so hierarchy comes
/// from the system's levels, solid fills become faint ones (a solid fill would turn into a block of
/// the tint), and what carries meaning joins the accent group (`widgetAccentable`).
struct WidgetTone {
    let mode: WidgetRenderingMode

    var isFullColor: Bool { mode == .fullColor }

    var ink: AnyShapeStyle { style(ZimamColor.ink, else: .primary) }
    var muted: AnyShapeStyle { style(ZimamColor.inkMuted, else: .secondary) }
    /// Padding days of a month grid.
    var faint: AnyShapeStyle { style(ZimamColor.inkFaint, else: .tertiary) }
    /// Chips, cells and tracks.
    var fill: AnyShapeStyle { style(ZimamColor.surfaceSunken, else: .quaternary) }
    /// Rings and the completion circle of a task without priority.
    var strong: AnyShapeStyle { style(ZimamColor.lineStrong, else: .secondary) }
    /// Prayer times only.
    var prayer: AnyShapeStyle { style(ZimamColor.sand, else: .secondary) }
    /// Late: overdue, or today's time already gone.
    var late: AnyShapeStyle { style(ZimamColor.priorityHigh, else: .primary) }
    /// Text on a solid colored badge or on today's filled circle.
    var onSolid: AnyShapeStyle { style(ZimamColor.surfaceRaised, else: .primary) }

    func priority(_ priority: TaskPriority) -> AnyShapeStyle {
        style(Self.color(priority), else: .primary)
    }

    /// Any token in full color, the system's level otherwise.
    func tinted(_ color: Color, else fallback: HierarchicalShapeStyle = .primary) -> AnyShapeStyle {
        style(color, else: fallback)
    }

    /// A span bar's fill: its priority color, light enough for `ink` text on it in both themes.
    func barFill(_ priority: TaskPriority) -> AnyShapeStyle {
        isFullColor ? AnyShapeStyle(Self.color(priority).opacity(WidgetMetrics.barOpacity)) : AnyShapeStyle(.quaternary)
    }

    /// The priority tokens; a task without priority gets the neutral border color.
    static func color(_ priority: TaskPriority) -> Color {
        switch priority {
        case .high: ZimamColor.priorityHigh
        case .medium: ZimamColor.priorityMedium
        case .low: ZimamColor.priorityLow
        case .none: ZimamColor.lineStrong
        }
    }

    private func style(_ color: Color, else fallback: HierarchicalShapeStyle) -> AnyShapeStyle {
        isFullColor ? AnyShapeStyle(color) : AnyShapeStyle(fallback)
    }
}

/// Sizes the widgets derive from the spacing tokens.
enum WidgetMetrics {
    /// The colored edge of a task chip.
    static let stripe = ZimamSpacing.space1 / 2
    /// Gap between chips and lanes.
    static let gap = ZimamSpacing.space1 / 2
    /// A one-line chip lane (caption text).
    static let lane = ZimamSpacing.space4 + ZimamSpacing.space1
    /// A two-line chip lane (time over title).
    static let tallLane = ZimamSpacing.space8 + ZimamSpacing.space1
    /// The tint behind a span bar. Light enough that `ink` on it keeps 4.5:1 in both themes.
    static let barOpacity = 0.22
    /// A task row with its completion circle: the 44pt touch target.
    static let row = ZimamSpacing.space11
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

// MARK: Pieces

/// The root modifiers of every widget in the family: Arabic, right to left, Thmanyah, and the
/// card surface as the removable container background.
struct WidgetFrame: ViewModifier {
    var padding: CGFloat? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, ZimamLocale.current)
            .font(ZimamType.body)
            .foregroundStyle(ZimamColor.ink)
            .containerBackground(for: .widget) { ZimamColor.surfaceRaised }
    }
}

extension View {
    func zimamWidget(padding: CGFloat? = nil) -> some View {
        modifier(WidgetFrame(padding: padding))
    }
}

/// The completion circle: an App Intent button, so the task is done without opening the app.
/// The circle takes the task's priority color; the target is 44pt.
struct WidgetCompleteButton: View {
    let item: WidgetItem
    let tone: WidgetTone

    var body: some View {
        Button(intent: CompleteTaskIntent(task: TaskEntity(id: item.id, title: item.title))) {
            Image(systemName: "circle")
                .font(ZimamType.headline)
                .foregroundStyle(item.priority == .none ? tone.strong : tone.priority(item.priority))
                .widgetAccentable(item.priority != .none)
                .frame(width: WidgetMetrics.row, height: WidgetMetrics.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("إنجاز \(item.title)")
    }
}

/// A number in a capsule: the count of a quadrant or of a month.
struct WidgetCountBadge: View {
    let count: Int
    /// Solid color behind the number; nil for a quiet badge on `surfaceSunken`.
    var color: Color?
    let tone: WidgetTone
    let locale: Locale

    var body: some View {
        Text(count.formatted(.number.locale(locale)))
            .font(ZimamType.caption)
            .foregroundStyle(color == nil ? tone.ink : tone.onSolid)
            .padding(.horizontal, ZimamSpacing.space2)
            .frame(minWidth: ZimamSpacing.space6)
            .background {
                if tone.isFullColor {
                    Capsule().fill(color ?? ZimamColor.surfaceSunken)
                } else {
                    Capsule().strokeBorder(.secondary)
                }
            }
            .widgetAccentable(color != nil)
            .accessibilityLabel(ArabicCount.tasks(count, locale: locale))
    }
}

/// A task on a calendar day: a colored edge (its priority) and its title, or its time over its
/// title when `time` is given. A task over several days is a tinted bar with its title.
struct WidgetTaskChip: View {
    let item: WidgetItem
    var time: String?
    var continuesBefore = false
    var continuesAfter = false
    let tone: WidgetTone

    var body: some View {
        HStack(spacing: ZimamSpacing.space1 / 2) {
            if !continuesBefore {
                Capsule()
                    .fill(item.priority == .none ? tone.strong : tone.priority(item.priority))
                    .frame(width: WidgetMetrics.stripe)
                    .padding(.vertical, WidgetMetrics.gap)
                    .widgetAccentable(item.priority != .none)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let time {
                    Text(time)
                        .font(ZimamType.caption)
                        .foregroundStyle(item.prayer != nil ? tone.prayer : tone.muted)
                        .lineLimit(1)
                }
                Text(item.title)
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, continuesBefore ? ZimamSpacing.space1 : WidgetMetrics.gap)
        .padding(.trailing, WidgetMetrics.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(item.isSpan ? tone.barFill(item.priority) : tone.fill, in: shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([time, item.title, priorityLabel(item.priority)].compactMap { $0 }.joined(separator: "، "))
    }

    /// Square ends where the bar goes on into the next or previous week.
    private var shape: UnevenRoundedRectangle {
        let radius = ZimamRadius.radiusSm
        return UnevenRoundedRectangle(topLeadingRadius: continuesBefore ? 0 : radius,
                                      bottomLeadingRadius: continuesBefore ? 0 : radius,
                                      bottomTrailingRadius: continuesAfter ? 0 : radius,
                                      topTrailingRadius: continuesAfter ? 0 : radius)
    }
}

/// «+٣»: tasks of a day that did not fit.
struct WidgetMoreLabel: View {
    let count: Int
    let tone: WidgetTone
    let locale: Locale

    var body: some View {
        Text("+\(count.formatted(.number.locale(locale)))")
            .font(ZimamType.caption)
            .foregroundStyle(tone.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, ZimamSpacing.space1)
            .accessibilityLabel("\(ArabicCount.tasks(count, locale: locale)) غيرها")
    }
}

/// One quiet sentence: signed out, or nothing to show.
struct WidgetNote: View {
    let text: String
    let tone: WidgetTone

    var body: some View {
        Text(text)
            .font(ZimamType.callout)
            .foregroundStyle(tone.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
