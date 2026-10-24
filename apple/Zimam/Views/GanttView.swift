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
    enum Zoom: Hashable { case days, weeks }

    /// The one sheet over the timeline: adding a task, or a task's «تغيير المدة…».
    private enum GanttSheet: Identifiable {
        case add
        case editSpan(taskId: UUID)

        var id: String {
            switch self {
            case .add: "add"
            case .editSpan(let taskId): "span-\(taskId.uuidString)"
            }
        }
    }

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

    let projectId: UUID?

    @State private var zoom: Zoom = .days
    /// nil follows the user's primary calendar (settings), as in the calendar.
    @State private var chosenKind: CalendarKind?
    @State private var selected: UUID?
    @State private var opened: TaskRoute?
    /// The add sheet or a task's «تغيير المدة…».
    @State private var presentedSheet: GanttSheet?
    /// Bumped to scroll to today («اليوم», and when the zoom changes).
    @State private var todayRequest = 0
    /// A task completed here stays a second so it can be undone.
    @State private var lingering = Lingering()

    @ScaledMetric(relativeTo: .body) private var rowHeight = ZimamSpacing.space11 + ZimamSpacing.space1

    // MARK: Rows

    /// Open top-level tasks with a due day, each group from its earliest start. A project's are
    /// grouped by section (those without one first), the whole timeline's by project, inbox first.
    private var groups: [GanttGroup] {
        let open = tasks.filter { $0.parentId == nil && (!$0.isDone || lingering.contains($0.id)) && $0.span != nil }
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
            let bySection = Dictionary(grouping: own, by: \.sectionId)
            if !loose.isEmpty {
                result.append(GanttGroup(id: "none", title: projectSections.isEmpty ? nil : "بلا قسم", rows: loose))
            }
            for section in projectSections {
                let items = rows(bySection[section.id] ?? [])
                if !items.isEmpty { result.append(GanttGroup(id: section.id.uuidString, title: section.name, rows: items)) }
            }
        } else {
            let byProject = Dictionary(grouping: open, by: \.projectId)
            let inbox = rows(byProject[nil] ?? [])
            if !inbox.isEmpty { result.append(GanttGroup(id: "inbox", title: "صندوق المهام", rows: inbox)) }
            for project in projects where project.kindRaw == ProjectRecord.Kind.project.rawValue {
                let items = rows(byProject[project.id] ?? [])
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

    /// The project's name over its timeline; nil for the whole timeline.
    private var projectTitle: String? {
        projectId.map { id in projects.first { $0.id == id }?.name ?? "" }
    }

    private var kindBinding: Binding<CalendarKind> {
        Binding(get: { kind }, set: { chosenKind = $0 })
    }

    private var firstWeekday: Int {
        if let start = session.user?.settings.weekStart, (0...6).contains(start) { return start + 1 }
        return Calendar.current.firstWeekday
    }

    private var today: String { formatter.dayString(from: DayClock.shared.now) }

    init(projectId: UUID?) {
        self.projectId = projectId
    }

    var body: some View {
        let groups = self.groups
        let undatedCount = self.undatedCount
        let range = TimelineRange.covering(groups.flatMap { $0.rows.map(\.span) }, today: today, firstWeekday: firstWeekday)
        VStack(alignment: .leading, spacing: 0) {
            GanttHeader(projectTitle: projectTitle, undatedCount: undatedCount, zoom: $zoom, kind: kindBinding)
                .padding(.horizontal, margin)
                .padding(.bottom, ZimamSpacing.space3)
            if groups.isEmpty {
                Text("لا مهام مفتوحة لها موعد. أضف موعداً لمهمة لتظهر هنا.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .padding(.horizontal, margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                GanttChart(groups: groups, range: range, zoom: zoom, kind: kind, today: today, rowHeight: rowHeight,
                           todayRequest: todayRequest, selected: selected,
                           onSelect: select, onOpen: open(_:), onCommit: commit, onEdit: editSpan, onComplete: complete)
            }
        }
        .background(ZimamColor.surface)
        .overlay(alignment: .bottomTrailing) { AddTaskButton { presentedSheet = .add } }
        .sheet(item: $presentedSheet) { route in sheetContent(route) }
        .navigationDestination(item: $opened) { route in TaskDetailView(taskId: route.id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("اليوم") { todayRequest += 1 }
                    .accessibilityHint("يعود إلى اليوم في المخطط")
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ route: GanttSheet) -> some View {
        switch route {
        case .add:
            AddTaskView(projectId: projectId)
        case .editSpan(let taskId):
            if let task = tasks.first(where: { $0.id == taskId }) {
                SpanEditSheet(task: task, kind: kind) { span in commit(task, span) }
            }
        }
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

    private func editSpan(_ task: TaskItem) {
        presentedSheet = .editSpan(taskId: task.id)
    }

    private func commit(_ task: TaskItem, _ span: DaySpan) {
        guard task.span != span else { return }
        withAnimation(.zimam(reduceMotion: reduceMotion)) {
            Store(context: context, sync: sync).setSpan(task, span)
        }
        let message: String = "«\(task.title)» \(formatter.withKind(kind).spanText(span))"
        AccessibilityNotification.Announcement(message).post()
    }

    private func complete(_ task: TaskItem) {
        withAnimation(.zimamComplete) { Store(context: context, sync: sync).toggleDone(task) }
        if task.isDone { lingering.hold(task.id, animation: .zimam(reduceMotion: reduceMotion)) }
    }
}

/// The timeline's title, its zoom and calendar choices, and how many tasks have no day.
private struct GanttHeader: View {
    /// The project's name, or nil for the whole timeline.
    let projectTitle: String?
    let undatedCount: Int
    @Binding var zoom: GanttView.Zoom
    @Binding var kind: CalendarKind

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space3) {
            if let projectTitle {
                ScreenHeader(title: projectTitle, subtitle: OverviewRoute.timeline.title)
            } else {
                ScreenHeader(title: OverviewRoute.timeline.title)
            }
            HStack(spacing: ZimamSpacing.space2) {
                ChoiceBar(label: "المقياس", options: [(GanttView.Zoom.days, "أيام"), (GanttView.Zoom.weeks, "أسابيع")],
                          selection: $zoom)
                ChoiceBar(label: "التقويم", options: [(CalendarKind.hijri, "هجري"), (CalendarKind.gregorian, "ميلادي")],
                          selection: $kind)
            }
            if undatedCount > 0 {
                Text("\(ArabicCount.tasks(undatedCount, locale: formatter.locale)) بلا موعد لا تظهر في المخطط.")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
    }
}

extension DualDateFormatter {
    /// The same formatter with `kind` first.
    func withKind(_ kind: CalendarKind) -> DualDateFormatter {
        var copy = self
        copy.primary = kind
        return copy
    }
}
