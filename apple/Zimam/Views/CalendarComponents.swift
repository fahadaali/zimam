import CoreTransferable
import SwiftUI
import ZimamKit

// The pieces of CalendarView: the month grid and its day cells, the week columns (iPad, Mac)
// and day lists (iPhone), the task rows that can be dragged to another day, and «نقل إلى…».

// MARK: Drag and drop

/// Dragging, plus the same move without dragging: «نقل إلى…» in the context menu and as a
/// VoiceOver action.
private struct CalendarTaskActions: ViewModifier {
    let task: TaskItem
    let onMove: (UUID) -> Void
    var onComplete: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .draggable(TaskDragItem(id: task.id)) { TaskDragPreview(title: task.title) }
            .contextMenu {
                if let onComplete {
                    Button("إنجاز", systemImage: "checkmark.circle", action: onComplete)
                }
                Button("نقل إلى…", systemImage: "calendar") { onMove(task.id) }
            }
            .accessibilityAction(named: "نقل إلى…") { onMove(task.id) }
    }
}

// MARK: Switches

/// A two-way switch («شهر / أسبوع», «هجري / ميلادي») with 44pt segments.
struct ChoiceBar<Value: Hashable>: View {
    let label: String
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: ZimamSpacing.space1) {
            ForEach(options, id: \.0) { option in
                let isSelected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(ZimamType.callout)
                        .foregroundStyle(isSelected ? ZimamColor.brandInk : ZimamColor.inkMuted)
                        .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
                        .background(isSelected ? ZimamColor.brandSoft : Color.clear,
                                    in: RoundedRectangle(cornerRadius: ZimamRadius.radiusSm))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(ZimamSpacing.space1)
        .background(ZimamColor.surfaceSunken, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd).strokeBorder(ZimamColor.lineStrong))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: Month

/// Seven columns from the week's first day at the leading edge (the right in Arabic), week by week.
/// Padding days of the months around are left empty. Under each week, a task that spans days is a
/// bar from its start day to its due day (`SpanLanes`); one-day tasks are dots in their day.
struct MonthGrid: View {
    let grid: CalendarGrid
    let days: [CalendarDay]
    let today: String
    @Binding var selectedDay: String
    let tasksByDay: [String: [TaskItem]]
    let spans: [SpanItem]
    let onDrop: ([UUID], String) -> Bool
    /// Apple Calendar's events, shown as outlined rings in their days.
    var events: [ShownEvent] = []

    @Environment(\.dateFormatterZimam) private var formatter
    // Not private, so the memberwise initializer stays internal.
    @ScaledMetric(relativeTo: .headline) var cellHeight = ZimamSpacing.space11 + ZimamSpacing.space6
    /// A bar in the month: one caption line.
    @ScaledMetric(relativeTo: .caption) var barHeight = ZimamSpacing.space6 - ZimamSpacing.space1

    var body: some View {
        let order = grid.weekdayOrder
        let short = formatter.weekdaySymbols(order, short: true)
        let full = formatter.weekdaySymbols(order, short: false)
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0 ..< min($0 + 7, days.count)]) }
        VStack(spacing: ZimamSpacing.space1) {
            HStack(spacing: ZimamSpacing.space1) {
                ForEach(order.indices, id: \.self) { index in
                    Text(short[index])
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(full[index])
                }
            }
            ForEach(weeks.indices, id: \.self) { index in
                week(weeks[index])
            }
        }
    }

    private func week(_ week: [CalendarDay]) -> some View {
        let inPeriod = week.filter(\.isInPeriod)
        let offset = week.firstIndex(where: \.isInPeriod) ?? 0
        return VStack(spacing: ZimamSpacing.space1) {
            HStack(spacing: ZimamSpacing.space1) {
                ForEach(week) { day in
                    if day.isInPeriod {
                        DayCell(day: day, kind: grid.kind, tasks: tasksByDay[day.day] ?? [],
                                spanCount: spans.filter { $0.span.contains(day.day) }.count,
                                isToday: day.day == today, isSelected: day.day == selectedDay, minHeight: cellHeight,
                                onSelect: { selectedDay = day.day },
                                onDrop: { onDrop($0, day.day) },
                                eventCount: events.filter { $0.span.contains(day.day) }.count)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: cellHeight)
                            .accessibilityHidden(true)
                    }
                }
            }
            // Bars are drawn over the month's own days only; VoiceOver hears them in each day's count
            // and in the selected day's list.
            SpanLanes(days: inPeriod.map(\.day), columnOffset: offset, columnCount: week.count, spans: spans,
                      maxLanes: 3, laneHeight: barHeight, spacing: ZimamSpacing.space1)
        }
    }
}

/// One day: the grid calendar's day large, the other calendar's small, and the day's tasks as dots.
/// Today has a ring; the selected day and a day under a dragged task are filled.
private struct DayCell: View {
    let day: CalendarDay
    let kind: CalendarKind
    let tasks: [TaskItem]
    /// Tasks that span this day, drawn as bars under the week.
    let spanCount: Int
    let isToday: Bool
    let isSelected: Bool
    let minHeight: CGFloat
    let onSelect: () -> Void
    let onDrop: ([UUID]) -> Bool
    /// Apple Calendar's events that day: outlined rings beside the task dots.
    var eventCount = 0

    @Environment(\.dateFormatterZimam) private var formatter
    // Not private: a private @State would make the memberwise initializer private.
    @State var isTargeted = false

    var body: some View {
        let highlighted = isSelected || isTargeted
        Button(action: onSelect) {
            VStack(spacing: 0) {
                Text(formatter.number(day.primaryDay))
                    .font(ZimamType.headline)
                    .foregroundStyle(highlighted ? ZimamColor.brandInk : ZimamColor.ink)
                Text(formatter.number(day.secondaryDay))
                    .font(ZimamType.caption)
                    .foregroundStyle(highlighted ? ZimamColor.brandInk : ZimamColor.inkMuted)
                HStack(spacing: ZimamSpacing.space1) {
                    TaskDots(tasks: tasks)
                    if eventCount > 0 { EventMarks(count: eventCount) }
                }
                .padding(.top, ZimamSpacing.space1)
            }
            .padding(.vertical, ZimamSpacing.space1)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .top)
            .background(highlighted ? ZimamColor.brandSoft : ZimamColor.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .overlay {
                if isToday || isTargeted {
                    RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
                        .strokeBorder(ZimamColor.lineStrong, lineWidth: ZimamSpacing.space1 / 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .taskDropDestination { items in
            onDrop(items.map(\.id))
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// «الثلاثاء، ٢ جمادى الأولى، ١٣ أكتوبر، اليوم، ٣ مهام».
    private var accessibilityText: String {
        var dates = formatter
        dates.primary = kind
        var parts = [formatter.weekday(day.date), dates.dual(day.date)]
        if isToday { parts.append("اليوم") }
        let count = tasks.count + spanCount
        if count > 0 { parts.append(ArabicCount.tasks(count, locale: formatter.locale)) }
        if eventCount > 0 { parts.append(ArabicCount.events(eventCount, locale: formatter.locale)) }
        return parts.joined(separator: "، ")
    }
}

/// Up to three dots (sand for a prayer-anchored task), or the count when there are more.
private struct TaskDots: View {
    let tasks: [TaskItem]

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        HStack(spacing: ZimamSpacing.space1 / 2) {
            if tasks.count > 3 {
                Text(formatter.number(tasks.count))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            } else {
                ForEach(tasks) { task in
                    Circle()
                        .fill(task.duePrayer != nil ? ZimamColor.sand : ZimamColor.inkMuted)
                        .frame(width: ZimamSpacing.space1 * 1.5, height: ZimamSpacing.space1 * 1.5)
                }
            }
        }
        .frame(minHeight: ZimamSpacing.space2)
        .accessibilityHidden(true)
    }
}

// MARK: Day

/// A day's heading and its open tasks in task rows. The whole section takes dropped tasks.
struct DayTasksSection: View {
    let date: Date
    let kind: CalendarKind
    let tasks: [TaskItem]
    let names: [UUID: String]
    let onDrop: ([UUID]) -> Bool
    let onMove: (UUID) -> Void
    let onToggle: (TaskItem) -> Void
    /// Apple Calendar's events that day, read only, above the tasks.
    var events: [ShownEvent] = []
    var onOpenEvent: (ShownEvent) -> Void = { _ in }

    @Environment(\.dateFormatterZimam) private var formatter
    // Not private: a private @State would make the memberwise initializer private.
    @State var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space3) {
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Text(heading.title)
                    .font(ZimamType.title)
                    .foregroundStyle(ZimamColor.ink)
                    .lineSpacing(ZimamType.titleLineSpacing)
                    .accessibilityAddTraits(.isHeader)
                Text(heading.subtitle)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            if !events.isEmpty {
                DayEventsList(events: events, onOpen: onOpenEvent)
            }
            if tasks.isEmpty {
                Text("لا مهام في هذا اليوم.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        CalendarTaskRow(task: task, projectName: task.projectId.flatMap { names[$0] },
                                        onMove: onMove, onToggle: { onToggle(task) })
                        if task.id != tasks.last?.id {
                            Divider()
                                .overlay(ZimamColor.line)
                                .padding(.leading, ZimamSpacing.space4)
                        }
                    }
                }
                .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
            }
        }
        // The highlight reaches past the content, so the layout does not move under the finger.
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusLg)
                    .fill(ZimamColor.brandSoft)
                    .padding(-ZimamSpacing.space2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .taskDropDestination { items in
            onDrop(items.map(\.id))
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    /// «اليوم» over «الخميس، ٤ جمادى الأولى ١٤٤٨، ١٥ أكتوبر ٢٠٢٦»; the weekday over the dates otherwise.
    private var heading: (title: String, subtitle: String) {
        var dates = formatter
        dates.primary = kind
        let full = dates.dual(date, withYear: true)
        let weekday = formatter.weekday(date)
        switch formatter.relativeWord(for: date) {
        case let word? where word != weekday: return (word, "\(weekday)، \(full)")
        default: return (weekday, full)
        }
    }
}

/// The task row of the lists, opening the task's details, draggable to another day.
private struct CalendarTaskRow: View {
    let task: TaskItem
    var projectName: String?
    let onMove: (UUID) -> Void
    let onToggle: () -> Void

    var body: some View {
        NavigationLink(value: TaskRoute(id: task.id)) {
            TaskRow(task: task, projectName: projectName, onToggle: onToggle)
                .padding(.horizontal, ZimamSpacing.space3)
                .padding(.vertical, ZimamSpacing.space2)
        }
        .buttonStyle(.plain)
        .modifier(CalendarTaskActions(task: task, onMove: onMove))
    }
}

// MARK: Week

/// Seven columns side by side (iPad and Mac), each taking dropped tasks. Tasks that span days are
/// bars across the columns, under the day headers.
struct WeekColumns: View {
    let days: [CalendarDay]
    let kind: CalendarKind
    let today: String
    @Binding var selectedDay: String
    let tasksByDay: [String: [TaskItem]]
    let spans: [SpanItem]
    let onDrop: ([UUID], String) -> Bool
    let onMove: (UUID) -> Void
    let onComplete: (TaskItem) -> Void
    /// Apple Calendar's events: all-day and spanning ones as outlined bars, timed ones in their columns.
    var events: [ShownEvent] = []
    var onOpenEvent: (ShownEvent) -> Void = { _ in }

    var body: some View {
        VStack(spacing: ZimamSpacing.space2) {
            HStack(alignment: .top, spacing: ZimamSpacing.space2) {
                ForEach(days) { day in
                    WeekDayHeader(day: day, kind: kind,
                                  taskCount: (tasksByDay[day.day]?.count ?? 0) + spans.filter { $0.span.contains(day.day) }.count,
                                  isToday: day.day == today, isSelected: day.day == selectedDay,
                                  onSelect: { selectedDay = day.day })
                }
            }
            EventLanes(days: days.map(\.day), events: events, spacing: ZimamSpacing.space2, onOpen: onOpenEvent)
            SpanLanes(days: days.map(\.day), columnOffset: 0, columnCount: days.count, spans: spans, maxLanes: 6,
                      laneHeight: ZimamSpacing.space11, spacing: ZimamSpacing.space2, interactive: true,
                      onMove: onMove, onComplete: onComplete)
            HStack(alignment: .top, spacing: ZimamSpacing.space2) {
                ForEach(days) { day in
                    WeekColumn(tasks: tasksByDay[day.day] ?? [],
                               onDrop: { onDrop($0, day.day) }, onMove: onMove, onComplete: onComplete,
                               events: events.filter { !$0.isWholeDay && $0.span.contains(day.day) },
                               onOpenEvent: onOpenEvent)
                }
            }
        }
    }
}

/// A day's name and both day numbers over its column; selects the day.
struct WeekDayHeader: View {
    let day: CalendarDay
    let kind: CalendarKind
    let taskCount: Int
    let isToday: Bool
    let isSelected: Bool
    /// The one-letter weekday («ح»), for the narrow strip on the iPhone.
    var short = false
    let onSelect: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 0) {
                Text(weekdayName)
                    .font(ZimamType.caption)
                    .foregroundStyle(isSelected ? ZimamColor.brandInk : ZimamColor.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(formatter.number(day.primaryDay))
                    .font(short ? ZimamType.headline : ZimamType.title)
                    .foregroundStyle(isSelected ? ZimamColor.brandInk : ZimamColor.ink)
                Text(formatter.number(day.secondaryDay))
                    .font(ZimamType.caption)
                    .foregroundStyle(isSelected ? ZimamColor.brandInk : ZimamColor.inkMuted)
            }
            .padding(.vertical, ZimamSpacing.space1)
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
            .background(isSelected ? ZimamColor.brandSoft : Color.clear, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
                        .strokeBorder(ZimamColor.lineStrong, lineWidth: ZimamSpacing.space1 / 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var weekdayName: String {
        guard short else { return formatter.weekday(day.date) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        return formatter.weekdaySymbols([calendar.component(.weekday, from: day.date)], short: true).first ?? ""
    }

    private var accessibilityText: String {
        var dates = formatter
        dates.primary = kind
        var parts = [formatter.weekday(day.date), dates.dual(day.date)]
        if isToday { parts.append("اليوم") }
        parts.append(ArabicCount.tasks(taskCount, locale: formatter.locale))
        return parts.joined(separator: "، ")
    }
}

/// A day's one-day tasks in a sunken column that takes dropped tasks, under the day's timed events.
private struct WeekColumn: View {
    let tasks: [TaskItem]
    let onDrop: ([UUID]) -> Bool
    let onMove: (UUID) -> Void
    let onComplete: (TaskItem) -> Void
    var events: [ShownEvent] = []
    var onOpenEvent: (ShownEvent) -> Void = { _ in }

    // Not private: a private @State would make the memberwise initializer private.
    @State var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            ForEach(events) { item in
                WeekEventCard(item: item) { onOpenEvent(item) }
            }
            ForEach(tasks) { task in
                WeekTaskCard(task: task, onMove: onMove, onComplete: { onComplete(task) })
            }
        }
        .padding(ZimamSpacing.space2)
        // Tall enough to drop onto even when the day is empty.
        .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space8 * 6, alignment: .top)
        .background(isTargeted ? ZimamColor.brandSoft : ZimamColor.surfaceSunken,
                    in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .taskDropDestination { items in
            onDrop(items.map(\.id))
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

/// The iPhone's week: a strip of the seven days with the tasks that span days as bars under them,
/// above the day lists. Tapping a day selects it; a bar opens its task.
struct WeekSpanStrip: View {
    let days: [CalendarDay]
    let kind: CalendarKind
    let today: String
    @Binding var selectedDay: String
    let tasksByDay: [String: [TaskItem]]
    let spans: [SpanItem]
    let onMove: (UUID) -> Void
    let onComplete: (TaskItem) -> Void

    var body: some View {
        VStack(spacing: ZimamSpacing.space1) {
            HStack(spacing: ZimamSpacing.space1) {
                ForEach(days) { day in
                    WeekDayHeader(day: day, kind: kind,
                                  taskCount: (tasksByDay[day.day]?.count ?? 0) + spans.filter { $0.span.contains(day.day) }.count,
                                  isToday: day.day == today, isSelected: day.day == selectedDay, short: true,
                                  onSelect: { selectedDay = day.day })
                }
            }
            SpanLanes(days: days.map(\.day), columnOffset: 0, columnCount: days.count, spans: spans, maxLanes: 4,
                      laneHeight: ZimamSpacing.space11, spacing: ZimamSpacing.space1, interactive: true,
                      onMove: onMove, onComplete: onComplete)
        }
        .padding(ZimamSpacing.space2)
        .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
    }
}

// MARK: Tasks that span days

/// A task that spans days, with its days.
struct SpanItem: Identifiable {
    let task: TaskItem
    let span: DaySpan

    var id: UUID { task.id }
}

/// The bars of the tasks that span days over one week's columns, in lanes under the dates.
/// `days` are the drawn days (a month's own days in its first and last weeks), starting at column
/// `columnOffset` of `columnCount`. A bar's leading end is its start day: the right in Arabic.
/// In the month the bars are a picture (`interactive` false: the day cells and the day's list carry
/// them for VoiceOver); in the week each bar opens its task, drags to another day, and has
/// «نقل إلى…» in its menu.
struct SpanLanes: View {
    let days: [String]
    let columnOffset: Int
    let columnCount: Int
    let spans: [SpanItem]
    let maxLanes: Int
    let laneHeight: CGFloat
    let spacing: CGFloat
    var interactive = false
    var onMove: (UUID) -> Void = { _ in }
    var onComplete: ((TaskItem) -> Void)?

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        let segments = SpanLayout.week(spans.map { (id: $0.id, span: $0.span) }, days: days, maxLanes: maxLanes).segments
        if !segments.isEmpty && columnCount > 0 {
            let lanes = (segments.map(\.lane).max() ?? 0) + 1
            let height = laneHeight * CGFloat(lanes) + spacing * CGFloat(lanes - 1)
            GeometryReader { geometry in
                let column = (geometry.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
                ZStack(alignment: .topLeading) {
                    ForEach(segments, id: \.self) { segment in
                        if let item = spans.first(where: { $0.id == segment.id }) {
                            bar(item)
                                .frame(width: column * CGFloat(segment.columnCount) + spacing * CGFloat(segment.columnCount - 1),
                                       height: laneHeight)
                                .padding(.leading, (column + spacing) * CGFloat(segment.firstColumn + columnOffset))
                                .padding(.top, (laneHeight + spacing) * CGFloat(segment.lane))
                        }
                    }
                }
                .frame(width: geometry.size.width, height: height, alignment: .topLeading)
            }
            .frame(height: height)
        }
    }

    @ViewBuilder
    private func bar(_ item: SpanItem) -> some View {
        let label = Text(item.task.title)
            .font(ZimamType.caption)
            .foregroundStyle(ZimamColor.onTimelineBar)
            .lineLimit(1)
            .padding(.horizontal, ZimamSpacing.space2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(ZimamColor.timelineBar, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusSm))
        if interactive {
            NavigationLink(value: TaskRoute(id: item.id)) {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(CalendarTaskActions(task: item.task, onMove: onMove,
                                          onComplete: onComplete.map { complete in { complete(item.task) } }))
            .accessibilityLabel("\(item.task.title)، \(formatter.spanText(item.span))")
        } else {
            label.accessibilityHidden(true)
        }
    }
}

/// A task in a week column: its title, and its prayer chip or clock time.
private struct WeekTaskCard: View {
    let task: TaskItem
    let onMove: (UUID) -> Void
    let onComplete: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        NavigationLink(value: TaskRoute(id: task.id)) {
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Text(task.title)
                    .font(ZimamType.callout)
                    .foregroundStyle(task.isDone ? ZimamColor.inkFaint : ZimamColor.ink)
                    .strikethrough(task.isDone)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let prayer = task.duePrayer {
                    PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: task.duePrayerOffset, locale: formatter.locale))
                } else if let time = clockTime {
                    Text(time)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
            .padding(ZimamSpacing.space2)
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CalendarTaskActions(task: task, onMove: onMove, onComplete: onComplete))
    }

    /// The task's "15:30" in the locale's clock: «٣:٣٠ م».
    private var clockTime: String? {
        guard let time = task.dueTime, let dueDate = task.dueDate, let day = formatter.date(fromDay: dueDate) else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        guard let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day) else { return nil }
        return formatter.time(date)
    }
}

// MARK: «نقل إلى…»

/// Moving a task to another day without dragging. The picker follows the calendar on screen.
struct MoveTaskSheet: View {
    let task: TaskItem
    let kind: CalendarKind
    let onMove: (String) -> Void

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(task: TaskItem, kind: CalendarKind, onMove: @escaping (String) -> Void) {
        self.task = task
        self.kind = kind
        self.onMove = onMove
        _date = State(initialValue: task.dueDate.flatMap { DualDateFormatter().date(fromDay: $0) } ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("اليوم الجديد", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.calendar, pickerCalendar)
                        .environment(\.locale, formatter.locale)
                    Text(dualText)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                } header: {
                    Text(task.title)
                        .textCase(nil)
                } footer: {
                    if let anchor {
                        Text(anchor)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("نقل إلى…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("نقل") {
                        onMove(formatter.dayString(from: date))
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space8 * 14)
        #endif
    }

    private var pickerCalendar: Calendar {
        var calendar = Calendar(identifier: kind.identifier)
        calendar.locale = formatter.locale
        calendar.timeZone = formatter.timeZone
        return calendar
    }

    private var dualText: String {
        var dates = formatter
        dates.primary = kind
        return dates.dual(date, withYear: true)
    }

    /// What stays the same on the new day.
    private var anchor: String? {
        if let prayer = task.duePrayer {
            return "تبقى «\(PrayerPhrase.text(prayer, offsetMinutes: task.duePrayerOffset, locale: formatter.locale))» في اليوم الجديد."
        }
        return task.dueTime == nil ? nil : "يبقى وقتها كما هو في اليوم الجديد."
    }
}
