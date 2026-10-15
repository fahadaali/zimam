import SwiftData
import SwiftUI
import ZimamKit

/// «المخطط الزمني»: a project's open tasks (or every project's and the inbox's, with
/// `projectId` nil) as bars on a horizontal time axis, one row per task, grouped by section
/// (or by project). A bar runs from the task's start day to its due day; a one-day task is a
/// diamond on its day. Time flows from the leading edge, so right to left in Arabic, under a
/// header with the months and days in both calendars and a line at today.
///
/// Changing the dates: select a bar (tap or click) and drag it to move it, or drag its ends to
/// change the start or the due day; on the Mac a bar drags without selecting it first. The same
/// change without dragging: «تغيير المدة…» in the bar's menu, VoiceOver's adjust (a day later or
/// earlier) and its actions. Tapping a selected bar opens the task.
struct GanttView: View {
    let projectId: UUID?

    enum Zoom: Hashable { case days, weeks }

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(SessionStore.self) private var session
    @Environment(\.taskSelection) private var taskSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete },
           sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }, sort: \ProjectItem.sortOrder)
    private var projects: [ProjectItem]
    @Query(filter: #Predicate<SectionItem> { !$0.pendingDelete },
           sort: [SortDescriptor(\SectionItem.sortOrder), SortDescriptor(\SectionItem.createdAt)])
    private var sections: [SectionItem]

    @State private var zoom: Zoom = .days
    /// nil follows the user's primary calendar (settings), as in the calendar.
    @State private var chosenKind: CalendarKind?
    @State private var selected: UUID?
    @State private var editing: SpanEditRequest?
    @State private var opened: TaskRoute?
    @State private var showingAdd = false
    /// Bumped to scroll to today («اليوم», and when the zoom changes).
    @State private var todayRequest = 0

    @ScaledMetric(relativeTo: .body) private var rowHeight = ZimamSpacing.space11 + ZimamSpacing.space1

    init(projectId: UUID?) {
        self.projectId = projectId
    }

    var body: some View {
        let groups = self.groups
        let undatedCount = self.undatedCount
        let range = TimelineRange.covering(groups.flatMap { $0.rows.map(\.span) }, today: today, firstWeekday: firstWeekday)
        VStack(alignment: .leading, spacing: 0) {
            header(undatedCount: undatedCount)
                .padding(.horizontal, margin)
                .padding(.bottom, ZimamSpacing.space3)
            if groups.isEmpty {
                Text("لا مهام مفتوحة لها موعد. أضف موعداً لمهمة لتظهر هنا.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .padding(.horizontal, margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                chart(groups: groups, range: range)
            }
        }
        .background(ZimamColor.surface)
        .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
        .sheet(isPresented: $showingAdd) { AddTaskView(projectId: projectId) }
        .sheet(item: $editing) { request in
            if let task = tasks.first(where: { $0.id == request.id }) {
                SpanEditSheet(task: task, kind: kind) { span in commit(task, span) }
            }
        }
        .navigationDestination(item: $opened) { route in TaskDetailView(taskId: route.id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("اليوم") { todayRequest += 1 }
                    .accessibilityHint("يعود إلى اليوم في المخطط")
            }
        }
    }

    // MARK: Header

    private func header(undatedCount: Int) -> some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space3) {
            if let projectId {
                ScreenHeader(title: projects.first { $0.id == projectId }?.name ?? "", subtitle: OverviewRoute.timeline.title)
            } else {
                ScreenHeader(title: OverviewRoute.timeline.title)
            }
            HStack(spacing: ZimamSpacing.space2) {
                ChoiceBar(label: "المقياس", options: [(Zoom.days, "أيام"), (Zoom.weeks, "أسابيع")], selection: zoomBinding)
                ChoiceBar(label: "التقويم", options: [(CalendarKind.hijri, "هجري"), (CalendarKind.gregorian, "ميلادي")],
                          selection: kindBinding)
            }
            if undatedCount > 0 {
                Text("\(ArabicCount.tasks(undatedCount, locale: formatter.locale)) بلا موعد لا تظهر في المخطط.")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
    }

    // MARK: Chart

    private func chart(groups: [GanttGroup], range: TimelineRange) -> some View {
        let dayWidth = zoom == .days ? ZimamSpacing.space11 : ZimamSpacing.space2
        let width = dayWidth * CGFloat(range.dayCount)
        let todayIndex = range.index(of: today).flatMap { (0 ..< range.dayCount).contains($0) ? $0 : nil }
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(groups) { group in
                            if let title = group.title {
                                GanttGroupHeader(title: title, leadingOffset: group.leadingColumn(in: range) * dayWidth,
                                                 width: width, height: rowHeight, todayX: todayX(todayIndex, dayWidth))
                            }
                            ForEach(group.rows) { row in
                                GanttRow(task: row.task, span: row.span, range: range, dayWidth: dayWidth, height: rowHeight,
                                         todayX: todayX(todayIndex, dayWidth), isSelected: selected == row.task.id,
                                         onSelect: { select(row.task) }, onOpen: { open(row.task) },
                                         onCommit: { commit(row.task, $0) },
                                         onEdit: { editing = SpanEditRequest(id: row.task.id) },
                                         onComplete: { complete(row.task) })
                            }
                        }
                    } header: {
                        GanttAxis(range: range, zoom: zoom, dayWidth: dayWidth, kind: kind, today: today,
                                  todayIndex: todayIndex)
                    }
                }
                .frame(width: width, alignment: .leading)
                // Room for the add button over the last row.
                .padding(.bottom, ZimamSpacing.space11 + ZimamSpacing.space8)
            }
            .onAppear { scrollToToday(proxy) }
            .onChange(of: todayRequest) { _, _ in scrollToToday(proxy) }
            .onChange(of: zoom) { _, _ in scrollToToday(proxy) }
        }
    }

    private func todayX(_ index: Int?, _ dayWidth: CGFloat) -> CGFloat? {
        index.map { CGFloat($0) * dayWidth + dayWidth / 2 }
    }

    private func scrollToToday(_ proxy: ScrollViewProxy) {
        // After the layout, so the marker exists.
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .default) {
                proxy.scrollTo(GanttAxis.todayID, anchor: .top)
            }
        }
    }

    // MARK: Rows

    /// Open top-level tasks with a due day, each group from its earliest start. A project's are
    /// grouped by section (those without one first), the whole timeline's by project, inbox first.
    private var groups: [GanttGroup] {
        let open = tasks.filter { $0.parentId == nil && !$0.isDone && $0.span != nil }
        func rows(_ items: [TaskItem]) -> [GanttRowData] {
            items.compactMap { task in task.span.map { GanttRowData(task: task, span: $0) } }
                .sorted { ($0.span.start, $0.span.end) < ($1.span.start, $1.span.end) }
        }
        var result: [GanttGroup] = []
        if let projectId {
            let own = open.filter { $0.projectId == projectId }
            let projectSections = sections.filter { $0.projectId == projectId }
            let known = Set(projectSections.map(\.id))
            let loose = rows(own.filter { $0.sectionId.map { !known.contains($0) } ?? true })
            if !loose.isEmpty {
                result.append(GanttGroup(id: "none", title: projectSections.isEmpty ? nil : "بلا قسم", rows: loose))
            }
            for section in projectSections {
                let items = rows(own.filter { $0.sectionId == section.id })
                if !items.isEmpty { result.append(GanttGroup(id: section.id.uuidString, title: section.name, rows: items)) }
            }
        } else {
            let inbox = rows(open.filter { $0.projectId == nil })
            if !inbox.isEmpty { result.append(GanttGroup(id: "inbox", title: "صندوق المهام", rows: inbox)) }
            for project in projects where project.kindRaw == ProjectRecord.Kind.project.rawValue {
                let items = rows(open.filter { $0.projectId == project.id })
                if !items.isEmpty { result.append(GanttGroup(id: project.id.uuidString, title: project.name, rows: items)) }
            }
        }
        return result
    }

    private var undatedCount: Int {
        tasks.filter { task in
            task.parentId == nil && !task.isDone && task.dueDate == nil && (projectId == nil || task.projectId == projectId)
        }.count
    }

    // MARK: Actions

    /// The first tap selects a bar (it then drags), the second opens its task: in the details
    /// column on the iPad and the Mac, pushed on the iPhone.
    private func select(_ task: TaskItem) {
        guard selected == task.id else {
            selected = task.id
            return
        }
        open(task)
    }

    private func open(_ task: TaskItem) {
        if let taskSelection {
            taskSelection.wrappedValue = TaskRoute(id: task.id)
        } else {
            opened = TaskRoute(id: task.id)
        }
    }

    private func commit(_ task: TaskItem, _ span: DaySpan) {
        guard task.span != span else { return }
        withAnimation(reduceMotion ? nil : .default) {
            Store(context: context, sync: sync).setSpan(task, span)
        }
        let message: String = "«\(task.title)» \(formatter.withKind(kind).spanText(span))"
        AccessibilityNotification.Announcement(message).post()
    }

    private func complete(_ task: TaskItem) {
        withAnimation(reduceMotion ? nil : .default) { Store(context: context, sync: sync).toggleDone(task) }
    }

    // MARK: State

    private var isRegular: Bool {
        #if os(iOS)
        return horizontalSizeClass == .regular
        #else
        return true
        #endif
    }

    private var margin: CGFloat { isRegular ? ZimamSpacing.space6 : ZimamSpacing.space4 }

    private var kind: CalendarKind { chosenKind ?? formatter.primary }

    private var kindBinding: Binding<CalendarKind> {
        Binding(get: { kind }, set: { chosenKind = $0 })
    }

    private var zoomBinding: Binding<Zoom> {
        Binding(get: { zoom }, set: { zoom = $0 })
    }

    private var firstWeekday: Int {
        if let start = session.user?.settings.weekStart, (0...6).contains(start) { return start + 1 }
        return Calendar.current.firstWeekday
    }

    private var today: String { formatter.dayString(from: Date()) }
}

/// The task whose «تغيير المدة…» sheet is open.
struct SpanEditRequest: Identifiable {
    let id: UUID
}

extension DualDateFormatter {
    /// The same formatter with `kind` first.
    func withKind(_ kind: CalendarKind) -> DualDateFormatter {
        var copy = self
        copy.primary = kind
        return copy
    }
}
