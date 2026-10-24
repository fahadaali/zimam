import SwiftData
import SwiftUI
import ZimamKit

/// The calendar: a month (or a week) in Hijri or Gregorian, each day with the other calendar's
/// day under it and dots for the open tasks due that day; a task that spans days is a bar from its
/// start day to its due day, under the week (`SpanLanes`). The selected day's tasks show under the
/// grid on iPhone and beside it on iPad and Mac. A task dragged onto a day moves there, keeping its
/// time or prayer anchor; «نقل إلى…» in its context menu does the same with a date picker.
struct CalendarView: View {
    enum Mode: Hashable { case month, week }

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(SessionStore.self) private var session
    @Environment(LocationProvider.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]

    @State private var mode: Mode = .month
    /// nil follows the user's primary calendar (settings); the switch on this screen overrides it.
    @State private var chosenKind: CalendarKind?
    /// The selected day as the API writes it. The month or week shown is the one that contains it.
    @State private var selectedDay = DualDateFormatter().dayString(from: Date())
    @State private var showingAdd = false
    @State private var moving: MoveRequest?
    /// Tasks completed here stay a second, so the completion can be undone.
    @State private var lingering = Lingering()
    /// «أحداث التقويم»: its settings sheet, and the event whose details are open.
    @State private var showingEventSettings = false
    @State private var openEvent: ShownEvent?

    init() {}

    var body: some View {
        let collected = tasksByDay()
        let names = projectNames(projects)
        content(byDay: collected.byDay, spans: collected.spans, names: names, events: visibleEvents())
            .background(ZimamColor.surface)
            .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
            .sheet(isPresented: $showingAdd) { addTaskSheet }
            .sheet(item: $moving) { request in
                if let task = tasks.first(where: { $0.id == request.id }) {
                    MoveTaskSheet(task: task, kind: kind) { day in reschedule([task.id], to: day) }
                }
            }
            #if os(iOS)
            .navigationTitle(isRegular ? "" : "التقويم")
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("اليوم") { selectedDay = today }
                        .accessibilityHint("يعود إلى اليوم في التقويم")
                }
                // iOS and macOS 26: «اليوم» in its own glass, apart from the calendar switch and events.
                if #available(iOS 26, macOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                if !isRegular {
                    // The iPhone's «هجري / ميلادي», out of the header to give the grid room.
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("التقويم", selection: kindBinding) {
                                Text("هجري").tag(CalendarKind.hijri)
                                Text("ميلادي").tag(CalendarKind.gregorian)
                            }
                        } label: {
                            Text(kind == .hijri ? "هجري" : "ميلادي")
                        }
                        .accessibilityLabel("التقويم المعروض")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    CalendarEventsMenu(showingSettings: $showingEventSettings)
                }
            }
            .sheet(isPresented: $showingEventSettings) { CalendarEventsSettingsSheet() }
            .sheet(item: $openEvent) { item in CalendarEventSheet(item: item) }
            .task {
                if CalendarEvents.shared.isShowing { CalendarEvents.shared.refresh() }
            }
            // A day opened from a widget (App/AppLinks.swift).
            .onChange(of: PlaceOpener.shared.pendingDay, initial: true) { _, day in
                guard let day else { return }
                selectedDay = day
                PlaceOpener.shared.pending = nil
            }
            // A new day (DayClock) moves a selection that was on today; a day picked on purpose stays.
            .onChange(of: today) { old, new in
                if selectedDay == old { selectedDay = new }
            }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(byDay: [String: [TaskItem]], spans: [SpanItem], names: [UUID: String],
                         events: [ShownEvent]) -> some View {
        switch mode {
        case .month:
            if isRegular {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: ZimamSpacing.space4) {
                            header
                            monthGrid(byDay, spans: spans, events: events)
                        }
                        .padding(margin)
                    }
                    .frame(maxWidth: .infinity)
                    Divider().overlay(ZimamColor.line)
                    ScrollView {
                        selectedDaySection(byDay, spans: spans, names: names, events: events)
                            .padding(margin)
                            .padding(.bottom, ZimamSpacing.space11 + ZimamSpacing.space8)
                    }
                    .frame(minWidth: ZimamSpacing.space8 * 9, idealWidth: ZimamSpacing.space8 * 11, maxWidth: ZimamSpacing.space8 * 13)
                }
            } else {
                ScrollView {
                    // The weekday row stays pinned under the toolbar while the grid scrolls, so the
                    // days keep their names; its surface hides the grid passing under it.
                    LazyVStack(alignment: .leading, spacing: ZimamSpacing.space4, pinnedViews: [.sectionHeaders]) {
                        header
                        Section {
                            monthGrid(byDay, spans: spans, events: events, compact: true)
                        } header: {
                            WeekdayRow(grid: grid)
                                .padding(.vertical, ZimamSpacing.space2)
                                .background(ZimamColor.surface)
                        }
                        selectedDaySection(byDay, spans: spans, names: names, events: events)
                            .padding(.top, ZimamSpacing.space2)
                    }
                    .padding(.horizontal, margin)
                    // Room for the add button over the last row.
                    .padding(.bottom, ZimamSpacing.space11 + ZimamSpacing.space8)
                }
            }
        case .week:
            let week = grid.weekDays(containing: selectedNoon)
            ScrollView {
                VStack(alignment: .leading, spacing: ZimamSpacing.space4) {
                    header
                    if isRegular {
                        WeekColumns(days: week, kind: kind, today: today, selectedDay: $selectedDay, tasksByDay: byDay,
                                    spans: spans, onDrop: reschedule, onMove: { moving = MoveRequest(id: $0) },
                                    onComplete: complete, events: events, onOpenEvent: { openEvent = $0 })
                    } else {
                        VStack(alignment: .leading, spacing: ZimamSpacing.space6) {
                            if spans.contains(where: { $0.span.overlaps(week.first?.day ?? "", week.last?.day ?? "") }) {
                                WeekSpanStrip(days: week, kind: kind, today: today, selectedDay: $selectedDay,
                                              tasksByDay: byDay, spans: spans, onMove: { moving = MoveRequest(id: $0) },
                                              onComplete: complete)
                            }
                            ForEach(week) { day in
                                DayTasksSection(date: day.date, kind: kind,
                                                tasks: dayList(day.day, byDay: byDay, spans: spans), names: names,
                                                onDrop: { reschedule($0, to: day.day) },
                                                onMove: { moving = MoveRequest(id: $0) }, onToggle: complete,
                                                events: dayEvents(day.day, events), onOpenEvent: { openEvent = $0 })
                            }
                        }
                    }
                }
                .padding(.horizontal, margin)
                .padding(.bottom, ZimamSpacing.space11 + ZimamSpacing.space8)
            }
        }
    }

    /// iPad and Mac: the large title, both switches side by side, and the period with its steps.
    /// iPhone: the title is the navigation bar's, the calendar switch is in the toolbar, and the
    /// period sits between its steps over a full-width «شهر / أسبوع», so the grid starts higher.
    @ViewBuilder
    private var header: some View {
        if isRegular {
            VStack(alignment: .leading, spacing: ZimamSpacing.space3) {
                ScreenHeader(title: "التقويم")
                HStack(spacing: ZimamSpacing.space2) {
                    ChoiceBar(label: "العرض", options: [(Mode.month, "شهر"), (Mode.week, "أسبوع")], selection: $mode)
                    ChoiceBar(label: "التقويم", options: [(CalendarKind.hijri, "هجري"), (CalendarKind.gregorian, "ميلادي")],
                              selection: kindBinding)
                }
                HStack(spacing: ZimamSpacing.space1) {
                    Text(periodTitle)
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.ink)
                        .lineSpacing(ZimamType.headlineLineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    stepButton(-1)
                    stepButton(1)
                }
            }
        } else {
            VStack(spacing: ZimamSpacing.space3) {
                HStack(spacing: ZimamSpacing.space1) {
                    stepButton(-1)
                    VStack(spacing: 0) {
                        Text(periodParts.primary)
                            .font(ZimamType.headline)
                            .foregroundStyle(ZimamColor.ink)
                        if let secondary = periodParts.secondary {
                            Text(secondary)
                                .font(ZimamType.caption)
                                .foregroundStyle(ZimamColor.inkMuted)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    stepButton(1)
                }
                ChoiceBar(label: "العرض", options: [(Mode.month, "شهر"), (Mode.week, "أسبوع")], selection: $mode)
            }
            .padding(.top, ZimamSpacing.space2)
        }
    }

    /// The period in the grid's calendar, and in the other one under it: «جمادى الأولى ١٤٤٨هـ»
    /// over «أكتوبر – نوفمبر ٢٠٢٦م».
    private var periodParts: (primary: String, secondary: String?) {
        let parts = periodTitle.components(separatedBy: "، ")
        guard parts.count > 1 else { return (periodTitle, nil) }
        return (parts[0], parts.dropFirst().joined(separator: "، "))
    }

    /// `compact`: the iPhone's quiet grid, under a weekday row the screen pins itself.
    private func monthGrid(_ byDay: [String: [TaskItem]], spans: [SpanItem], events: [ShownEvent],
                           compact: Bool = false) -> some View {
        MonthGrid(grid: grid, days: grid.monthDays(containing: selectedNoon), today: today,
                  selectedDay: $selectedDay, tasksByDay: byDay, spans: spans, onDrop: reschedule, events: events,
                  showsWeekdayRow: !compact, isCompact: compact)
    }

    private func selectedDaySection(_ byDay: [String: [TaskItem]], spans: [SpanItem], names: [UUID: String],
                                    events: [ShownEvent]) -> some View {
        DayTasksSection(date: grid.date(fromDay: selectedDay) ?? selectedNoon, kind: kind,
                        tasks: dayList(selectedDay, byDay: byDay, spans: spans), names: names,
                        onDrop: { reschedule($0, to: selectedDay) },
                        onMove: { moving = MoveRequest(id: $0) }, onToggle: complete,
                        events: dayEvents(selectedDay, events), onOpenEvent: { openEvent = $0 })
    }

    /// Previous or next month (or week). In a right-to-left layout the backward chevron points right.
    private func stepButton(_ direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: direction < 0 ? "chevron.backward" : "chevron.forward")
                .font(ZimamType.headline)
                .foregroundStyle(ZimamColor.ink)
                .frame(width: ZimamSpacing.space11, height: ZimamSpacing.space11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stepLabel(direction))
    }

    private func stepLabel(_ direction: Int) -> String {
        switch (mode, direction < 0) {
        case (.month, true): "الشهر السابق"
        case (.month, false): "الشهر التالي"
        case (.week, true): "الأسبوع السابق"
        case (.week, false): "الأسبوع التالي"
        }
    }

    private var addTaskSheet: some View {
        let tomorrow = grid.dayString(from: grid.addingDays(1, to: DayClock.shared.now))
        let due: AddTaskView.Due = selectedDay == today ? .today : selectedDay == tomorrow ? .tomorrow : .pickedDate
        return AddTaskView(due: due, date: selectedNoon)
    }

    // MARK: State

    private var isRegular: Bool {
        #if os(iOS)
        return horizontalSizeClass == .regular
        #else
        return true
        #endif
    }

    /// `space4` on the iPhone, `space6` on iPad and Mac (design/README.md, «المسافات»).
    private var margin: CGFloat { isRegular ? ZimamSpacing.space6 : ZimamSpacing.space4 }

    private var kind: CalendarKind { chosenKind ?? formatter.primary }

    private var kindBinding: Binding<CalendarKind> {
        Binding(get: { kind }, set: { chosenKind = $0 })
    }

    /// The week starts on the day chosen in settings («بداية الأسبوع»), or the system's.
    private var firstWeekday: Int {
        if let start = session.user?.settings.weekStart, (0...6).contains(start) { return start + 1 }
        return Calendar.current.firstWeekday
    }

    private var grid: CalendarGrid {
        CalendarGrid(kind: kind, firstWeekday: firstWeekday, timeZone: formatter.timeZone)
    }

    private var today: String { formatter.dayString(from: DayClock.shared.now) }

    /// Midday of the selected day, away from either edge of it.
    private var selectedNoon: Date {
        (grid.date(fromDay: selectedDay) ?? Date()).addingTimeInterval(12 * 3600)
    }

    private var periodTitle: String {
        if mode == .month { return formatter.monthTitle(selectedNoon, in: kind) }
        let week = grid.weekDays(containing: selectedNoon)
        guard let first = week.first, let last = week.last else { return "" }
        return formatter.rangeTitle(from: first.date, to: last.date, in: kind)
    }

    private func step(_ direction: Int) {
        let moved = mode == .month
            ? grid.addingMonths(direction, to: selectedNoon)
            : grid.addingDays(7 * direction, to: selectedNoon)
        selectedDay = grid.dayString(from: moved)
    }

    // MARK: Tasks

    /// Open top-level tasks by due day (as in «اليوم» and «القادم»), ordered by time of day:
    /// tasks without a time first, then by clock or prayer time. Tasks that span days come apart,
    /// as bars, with their start days; they reach the day lists through `dayList`.
    /// Only the days on screen (with the month grid's padding days) are collected.
    private func tasksByDay() -> (byDay: [String: [TaskItem]], spans: [SpanItem]) {
        let visible = mode == .month ? grid.monthDays(containing: selectedNoon) : grid.weekDays(containing: selectedNoon)
        guard let first = visible.first?.day, let last = visible.last?.day else { return ([:], []) }
        let schedule = location.schedule(session.user?.settings)
        var result: [String: [TaskItem]] = [:]
        var spans: [SpanItem] = []
        for task in tasks where task.parentId == nil && (!task.isDone || lingering.contains(task.id)) {
            // API days ("2026-10-15") sort as text.
            guard let span = task.span, span.overlaps(first, last) else { continue }
            if span.isMultiDay {
                spans.append(SpanItem(task: task, span: span))
            } else {
                result[span.end, default: []].append(task)
            }
        }
        let byDay = result.mapValues { items in
            items.map { (task: $0, minute: minuteOfDay($0, schedule: schedule) ?? -1) }
                .sorted { ($0.minute, $0.task.sortOrder) < ($1.minute, $1.task.sortOrder) }
                .map { $0.task }
        }
        return (byDay, spans.sorted { ($0.span.start, $0.span.end) < ($1.span.start, $1.span.end) })
    }

    // MARK: Calendar events

    /// Apple Calendar's events on the days on screen, when «إظهار أحداث التقويم» is on.
    private func visibleEvents() -> [ShownEvent] {
        let visible = mode == .month ? grid.monthDays(containing: selectedNoon) : grid.weekDays(containing: selectedNoon)
        guard let first = visible.first?.day, let last = visible.last?.day else { return [] }
        return CalendarEvents.shared.events(from: first, to: last, timeZone: formatter.timeZone)
    }

    /// The events that touch `day`, in day order.
    private func dayEvents(_ day: String, _ events: [ShownEvent]) -> [ShownEvent] {
        events.filter { $0.span.contains(day) }
    }

    /// A day's list: the tasks that span it first, then the ones due that day.
    private func dayList(_ day: String, byDay: [String: [TaskItem]], spans: [SpanItem]) -> [TaskItem] {
        spans.filter { $0.span.contains(day) }.map(\.task) + (byDay[day] ?? [])
    }

    /// Minutes after midnight for ordering: the clock time, or the prayer's time with its offset.
    private func minuteOfDay(_ task: TaskItem, schedule: PrayerSchedule?) -> Int? {
        if let prayer = task.duePrayer {
            let offset = task.duePrayerOffset ?? 0
            if let schedule, let day = task.dueDate.flatMap(formatter.date(fromDay:)),
               let time = schedule.time(of: prayer, on: day.addingTimeInterval(12 * 3600), offsetMinutes: offset) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = formatter.timeZone
                let parts = calendar.dateComponents([.hour, .minute], from: time)
                return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
            // No location yet: a usual time for each prayer is close enough to sort by.
            let usual = switch prayer {
            case .fajr: 5 * 60
            case .dhuhr: 12 * 60
            case .asr: 15 * 60
            case .maghrib: 18 * 60
            case .isha: 19 * 60 + 30
            }
            return usual + offset
        }
        guard let time = task.dueTime else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// Moves tasks to `day`, keeping each one's time or prayer anchor. Used by drops and «نقل إلى…».
    @discardableResult
    private func reschedule(_ ids: [UUID], to day: String) -> Bool {
        let moved = tasks.filter { ids.contains($0.id) && $0.dueDate != day }
        guard !moved.isEmpty else { return false }
        let store = Store(context: context, sync: sync)
        withAnimation(.zimam(reduceMotion: reduceMotion)) {
            for task in moved { store.reschedule(task, toDay: day) }
        }
        if let date = formatter.date(fromDay: day) {
            var dates = formatter
            dates.primary = kind
            let message = "نُقلت إلى \(dates.dual(date))"
            AccessibilityNotification.Announcement(message).post()
        }
        return true
    }

    private func complete(_ task: TaskItem) {
        withAnimation(.zimamComplete) { Store(context: context, sync: sync).toggleDone(task) }
        if task.isDone { lingering.hold(task.id, animation: .zimam(reduceMotion: reduceMotion)) }
    }
}

/// The task whose «نقل إلى…» sheet is open.
private struct MoveRequest: Identifiable {
    let id: UUID
}
