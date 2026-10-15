import SwiftUI
import ZimamKit

// The pieces of GanttView: the groups and rows, the axis with both calendars, a task's bar with
// its drag handles, and «تغيير المدة…». Positions are leading offsets (`padding(.leading:)`), so
// the chart mirrors itself in Arabic: the first day is at the right and time runs leftwards.

// MARK: Data

/// A task on the timeline with its days.
struct GanttRowData: Identifiable {
    let task: TaskItem
    let span: DaySpan

    var id: UUID { task.id }
}

/// A section of a project, or a project in the whole timeline, with its rows by start day.
struct GanttGroup: Identifiable {
    let id: String
    /// nil for a project's tasks without a section when it has no sections at all.
    let title: String?
    let rows: [GanttRowData]

    /// The column of the group's earliest start, where its title is written.
    func leadingColumn(in range: TimelineRange) -> CGFloat {
        guard let first = rows.map(\.span.start).min(), let index = range.index(of: first) else { return 0 }
        return CGFloat(min(max(index, 0), range.dayCount - 1))
    }
}

// MARK: Rows

/// The line at today, through every row.
private struct TodayLine: View {
    var body: some View {
        Rectangle()
            .fill(ZimamColor.timelineToday)
            .frame(width: ZimamLayout.focusRingWidth)
            .accessibilityHidden(true)
    }
}

/// A group's name, written above its rows where its earliest task starts.
struct GanttGroupHeader: View {
    let title: String
    let leadingOffset: CGFloat
    let width: CGFloat
    let height: CGFloat
    let todayX: CGFloat?

    var body: some View {
        ZStack(alignment: .leading) {
            if let todayX {
                TodayLine().padding(.leading, max(todayX - ZimamLayout.focusRingWidth / 2, 0))
            }
            Text(title)
                .font(ZimamType.headline)
                .foregroundStyle(ZimamColor.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, leadingOffset + ZimamSpacing.space1)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(ZimamColor.surfaceSunken)
    }
}

/// One task: its bar (or a diamond for a one-day task) at its days, its title inside the bar when
/// it fits and after it otherwise.
struct GanttRow: View {
    enum Part { case whole, start, end }

    let task: TaskItem
    let span: DaySpan
    let range: TimelineRange
    let dayWidth: CGFloat
    let height: CGFloat
    let todayX: CGFloat?
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onCommit: (DaySpan) -> Void
    let onEdit: () -> Void
    let onComplete: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.layoutDirection) private var layoutDirection
    /// The days while a drag is under way. Not private, so the memberwise initializer stays internal.
    @State var preview: DaySpan?

    private var barHeight: CGFloat { max(height - ZimamSpacing.space3, ZimamSpacing.space6) }
    /// The width of a drag handle at either end of a bar.
    private var handleWidth: CGFloat { ZimamSpacing.space3 }

    /// On the iPhone and iPad a bar drags once selected, so a swipe across the chart still
    /// scrolls it; with a pointer it drags straight away.
    private var canDrag: Bool {
        #if os(macOS)
        return true
        #else
        return isSelected
        #endif
    }

    var body: some View {
        let shown = preview ?? span
        ZStack(alignment: .leading) {
            if let todayX {
                TodayLine().padding(.leading, max(todayX - ZimamLayout.focusRingWidth / 2, 0))
            }
            if let columns = range.columns(of: shown) {
                let multiDay = shown.isMultiDay
                let barWidth = multiDay ? CGFloat(columns.count) * dayWidth - ZimamLayout.focusRingWidth : max(dayWidth, barHeight)
                let x = multiDay
                    ? CGFloat(columns.first) * dayWidth + ZimamLayout.focusRingWidth / 2
                    : max(CGFloat(columns.first) * dayWidth + dayWidth / 2 - barWidth / 2, 0)
                let titleInside = multiDay && barWidth >= ZimamSpacing.space11 * 3
                HStack(spacing: ZimamSpacing.space2) {
                    marker(multiDay: multiDay, width: barWidth, titleInside: titleInside)
                    if !titleInside {
                        Text(task.title)
                            .font(ZimamType.callout)
                            .foregroundStyle(ZimamColor.ink)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.leading, x)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(task.title)، \(formatter.spanText(span))")
                .accessibilityHint("اسحب الشريط أو طرفيه لتغيير المدة، أو استعمل «تغيير المدة…».")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(.default, onOpen)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onCommit(span.moved(by: 1))
                    case .decrement: onCommit(span.moved(by: -1))
                    @unknown default: break
                    }
                }
                .accessibilityAction(named: "تغيير المدة…", onEdit)
                .accessibilityAction(named: "إنجاز", onComplete)
            }
        }
        .frame(width: CGFloat(range.dayCount) * dayWidth, height: height, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ZimamColor.line).frame(height: 1).accessibilityHidden(true)
        }
    }

    /// The bar, or the diamond of a one-day task, with the drag handles when it can be dragged.
    private func marker(multiDay: Bool, width: CGFloat, titleInside: Bool) -> some View {
        ZStack {
            if multiDay {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusSm)
                    .fill(ZimamColor.timelineBar)
                if titleInside {
                    Text(task.title)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.onTimelineBar)
                        .lineLimit(1)
                        .padding(.horizontal, handleWidth)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Rectangle()
                    .fill(ZimamColor.timelineBar)
                    .frame(width: ZimamSpacing.space3, height: ZimamSpacing.space3)
                    .rotationEffect(.degrees(45))
            }
        }
        .frame(width: width, height: barHeight)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusSm)
                    .strokeBorder(ZimamColor.focusRing, lineWidth: ZimamLayout.focusRingWidth)
                    .padding(-ZimamLayout.focusRingWidth * 2)
            }
        }
        .overlay(alignment: .leading) { handle(.start, visible: showsHandles(width)) }
        .overlay(alignment: .trailing) { handle(.end, visible: showsHandles(width)) }
        .contentShape(Rectangle())
        .gesture(drag(.whole), including: canDrag ? .all : .subviews)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("فتح المهمة", systemImage: "arrow.up.forward.square", action: onOpen)
            Button("تغيير المدة…", systemImage: "calendar", action: onEdit)
            Button("إنجاز", systemImage: "checkmark.circle", action: onComplete)
        }
    }

    /// Handles on a task that spans days and is wide enough for both; kept while dragging one.
    private func showsHandles(_ width: CGFloat) -> Bool {
        canDrag && (preview != nil || (span.isMultiDay && width >= handleWidth * 3))
    }

    @ViewBuilder
    private func handle(_ part: Part, visible: Bool) -> some View {
        if visible {
            Capsule()
                .fill(ZimamColor.onTimelineBar)
                .frame(width: ZimamLayout.focusRingWidth, height: barHeight / 2)
                .frame(width: handleWidth, height: barHeight)
                .contentShape(Rectangle())
                .gesture(drag(part))
                .accessibilityHidden(true)
        }
    }

    private func drag(_ part: Part) -> some Gesture {
        // Screen coordinates: their x grows to the right whatever the layout direction.
        DragGesture(minimumDistance: ZimamSpacing.space1, coordinateSpace: .global)
            .onChanged { value in preview = changed(part, by: value.translation.width) }
            .onEnded { value in
                let result = changed(part, by: value.translation.width)
                preview = nil
                if result != span { onCommit(result) }
            }
    }

    private func changed(_ part: Part, by translation: CGFloat) -> DaySpan {
        let days = TimelineDrag.days(translation: Double(translation), dayWidth: Double(dayWidth),
                                     rightToLeft: layoutDirection == .rightToLeft)
        switch part {
        case .whole: return span.moved(by: days)
        case .start: return span.movingStart(by: days)
        case .end: return span.movingEnd(by: days)
        }
    }
}

// MARK: Axis

/// The header pinned over the rows: the months of the user's primary calendar, then the other
/// calendar's, then the days (or the weeks), each day with both its numbers.
struct GanttAxis: View {
    static let todayID = "gantt-today"

    let range: TimelineRange
    let zoom: GanttView.Zoom
    let dayWidth: CGFloat
    let kind: CalendarKind
    let today: String
    let todayIndex: Int?

    @Environment(\.dateFormatterZimam) private var formatter

    private struct MonthSegment: Identifiable {
        let start: Int
        let count: Int
        let title: String

        var id: Int { start }
    }

    var body: some View {
        let dates = (0 ..< range.dayCount).map { noon(of: range.day(at: $0)) }
        VStack(alignment: .leading, spacing: 0) {
            monthRow(dates, in: kind, primary: true)
            monthRow(dates, in: kind.other, primary: false)
            if zoom == .days {
                dayRow(dates)
            } else {
                weekRow(dates)
            }
        }
        .padding(.vertical, ZimamSpacing.space1)
        .frame(width: dayWidth * CGFloat(range.dayCount), alignment: .leading)
        .overlay(alignment: .leading) {
            if let todayIndex {
                TodayLine()
                    .id(Self.todayID)
                    .padding(.leading, CGFloat(todayIndex) * dayWidth + dayWidth / 2 - ZimamLayout.focusRingWidth / 2)
            }
        }
        .background(ZimamColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ZimamColor.line).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(dates))
    }

    private func monthRow(_ dates: [Date], in kind: CalendarKind, primary: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(segments(dates, in: kind)) { segment in
                Text(segment.title)
                    .font(ZimamType.caption)
                    .foregroundStyle(primary ? ZimamColor.ink : ZimamColor.inkMuted)
                    .lineLimit(1)
                    .padding(.horizontal, ZimamSpacing.space1)
                    .frame(width: CGFloat(segment.count) * dayWidth, alignment: .leading)
                    .clipped()
                    .overlay(alignment: .leading) {
                        Rectangle().fill(ZimamColor.line).frame(width: 1)
                    }
            }
        }
    }

    private func dayRow(_ dates: [Date]) -> some View {
        let primary = calendar(kind)
        let other = calendar(kind.other)
        let weekdays = Calendar(identifier: .gregorian)
        return HStack(spacing: 0) {
            ForEach(dates.indices, id: \.self) { index in
                let date = dates[index]
                let isToday = index == todayIndex
                VStack(spacing: 0) {
                    Text(formatter.weekdaySymbols([weekdays.component(.weekday, from: date)], short: true).first ?? "")
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                    Text(formatter.number(primary.component(.day, from: date)))
                        .font(ZimamType.headline)
                        .foregroundStyle(isToday ? ZimamColor.timelineToday : ZimamColor.ink)
                    Text(formatter.number(other.component(.day, from: date)))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                .frame(width: dayWidth)
            }
        }
        .padding(.top, ZimamSpacing.space1)
    }

    /// A column a week wide: its first day in both calendars.
    private func weekRow(_ dates: [Date]) -> some View {
        let primary = calendar(kind)
        let other = calendar(kind.other)
        let starts = Array(stride(from: 0, to: dates.count, by: 7))
        return HStack(spacing: 0) {
            ForEach(starts, id: \.self) { start in
                let date = dates[start]
                let hasToday = todayIndex.map { (start ..< start + 7).contains($0) } ?? false
                VStack(alignment: .leading, spacing: 0) {
                    Text(formatter.number(primary.component(.day, from: date)))
                        .font(ZimamType.headline)
                        .foregroundStyle(hasToday ? ZimamColor.timelineToday : ZimamColor.ink)
                    Text(formatter.number(other.component(.day, from: date)))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                .padding(.horizontal, ZimamSpacing.space1)
                .frame(width: dayWidth * 7, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(ZimamColor.line).frame(width: 1)
                }
            }
        }
        .padding(.top, ZimamSpacing.space1)
    }

    /// Consecutive days of the same month in `kind`, with «جمادى الأولى ١٤٤٨هـ».
    private func segments(_ dates: [Date], in kind: CalendarKind) -> [MonthSegment] {
        let calendar = self.calendar(kind)
        let names = DateFormatter()
        names.calendar = calendar
        names.locale = formatter.locale
        names.timeZone = formatter.timeZone
        names.dateFormat = "MMMM y"
        var result: [MonthSegment] = []
        var key: DateComponents?
        for (index, date) in dates.enumerated() {
            let month = calendar.dateComponents([.year, .month], from: date)
            if month == key, let last = result.popLast() {
                result.append(MonthSegment(start: last.start, count: last.count + 1, title: last.title))
            } else {
                key = month
                result.append(MonthSegment(start: index, count: 1, title: names.string(from: date) + kind.yearSuffix))
            }
        }
        return result
    }

    private func calendar(_ kind: CalendarKind) -> Calendar {
        var calendar = Calendar(identifier: kind.identifier)
        calendar.timeZone = formatter.timeZone
        return calendar
    }

    /// Midday of an API day, away from either edge of it.
    private func noon(of day: String) -> Date {
        (formatter.date(fromDay: day) ?? Date()).addingTimeInterval(12 * 3600)
    }

    private func accessibilityText(_ dates: [Date]) -> String {
        guard let first = dates.first, let last = dates.last else { return "" }
        return "المخطط من \(formatter.withKind(kind).rangeTitle(from: first, to: last, in: kind))"
    }
}

// MARK: «تغيير المدة…»

/// A task's start and due days without dragging, in the calendar the timeline shows. The start
/// can only be before the due day (its picker stops the day before).
struct SpanEditSheet: View {
    let task: TaskItem
    let kind: CalendarKind
    let onSave: (DaySpan) -> Void

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.dismiss) private var dismiss
    @State private var due: Date
    @State private var hasStart: Bool
    @State private var start: Date

    init(task: TaskItem, kind: CalendarKind, onSave: @escaping (DaySpan) -> Void) {
        self.task = task
        self.kind = kind
        self.onSave = onSave
        let days = DualDateFormatter()
        let due = task.dueDate.flatMap { days.date(fromDay: $0) } ?? Calendar.current.startOfDay(for: Date())
        _due = State(initialValue: due)
        _hasStart = State(initialValue: task.startDate != nil)
        let dayBefore = DayMath.adding(-1, to: days.dayString(from: due)).flatMap { days.date(fromDay: $0) } ?? due
        _start = State(initialValue: task.startDate.flatMap { days.date(fromDay: $0) } ?? dayBefore)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("الاستحقاق", selection: $due, displayedComponents: .date)
                        .environment(\.calendar, pickerCalendar)
                        .environment(\.locale, formatter.locale)
                    Text(dates.dual(due, withYear: true))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                } header: {
                    Text(task.title)
                        .textCase(nil)
                }
                Section {
                    Toggle("تاريخ البداية", isOn: $hasStart)
                    if hasStart {
                        DatePicker("البداية", selection: $start, in: ...latestStart, displayedComponents: .date)
                            .environment(\.calendar, pickerCalendar)
                            .environment(\.locale, formatter.locale)
                        Text(dates.dual(start, withYear: true))
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                } footer: {
                    Text(dates.spanText(span))
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("تغيير المدة…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        onSave(span)
                        dismiss()
                    }
                }
            }
            .onChange(of: due) { _, _ in
                if start > latestStart { start = latestStart }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space8 * 12)
        #endif
    }

    private var dates: DualDateFormatter { formatter.withKind(kind) }

    /// The day before the due day.
    private var latestStart: Date {
        DayMath.adding(-1, to: formatter.dayString(from: due)).flatMap { formatter.date(fromDay: $0) } ?? due
    }

    private var span: DaySpan {
        let end = formatter.dayString(from: due)
        let first = hasStart ? min(formatter.dayString(from: start), end) : end
        return DaySpan(start: first, end: end)
    }

    private var pickerCalendar: Calendar {
        var calendar = Calendar(identifier: kind.identifier)
        calendar.locale = formatter.locale
        calendar.timeZone = formatter.timeZone
        return calendar
    }
}
