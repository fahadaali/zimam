import SwiftData
import SwiftUI
import ZimamKit

/// The signed-in app. On the iPhone (compact width) the five tabs; on the iPad and the Mac
/// (regular width) two columns, the sidebar and the content across the rest of the window, with
/// the task's details in an inspector that slides in only while a task is open (on the
/// trailing side, the left in Arabic), so lists, boards and the timeline get the full width. Where the user is lives here, above both layouts, so it
/// carries across rotation, Split View and Slide Over, and is saved per window.
struct MainView: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync

    @SceneStorage("main.sidebar") private var sidebar: SidebarItem = .today
    @SceneStorage("main.tab") private var tab: MainTab = .today
    @SceneStorage("main.task") private var selectedTaskId = ""
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var todayPath = NavigationPath()
    @State private var upcomingPath = NavigationPath()
    @State private var calendarPath = NavigationPath()
    @State private var projectsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var newTask: NewTaskRequest?
    /// ⌘F or «بحث» asked for the search field: `SearchView` focuses it and clears this.
    @State private var searchFocusPending = false
    /// The calendar's selected day, for «مهمة جديدة» (⌘N) while the calendar shows.
    @State private var calendarDay: String?
    /// ⌫ on the Mac asked to delete the selected task: the same confirmation as its details.
    @State private var confirmingDelete = false

    init() {}

    private var isRegular: Bool {
        #if os(iOS)
        return sizeClass == .regular
        #else
        return true
        #endif
    }

    var body: some View {
        Group {
            if isRegular {
                splitView
            } else {
                tabView
            }
        }
        .onChange(of: isRegular) { _, regular in
            if regular { widen() } else { narrow() }
        }
        .focusedSceneValue(\.zimamActions, actions)
        // A project deleted or archived while open (ProjectOptions.swift): its column closes.
        .environment(\.projectClosed, { id in
            guard sidebar.projectId == id else { return }
            sidebar = .inbox
            selectedTaskId = ""
        })
        // A task opened from Siri, Shortcuts or Spotlight (OpenTaskIntent).
        .onChange(of: TaskOpener.shared.pending, initial: true) { _, id in
            guard let id else { return }
            TaskOpener.shared.pending = nil
            open(taskId: id)
        }
        // «اليوم», «التقويم», a day or «المصفوفة», opened from a widget (App/AppLinks.swift).
        .onChange(of: PlaceOpener.shared.pending, initial: true) { _, link in
            guard let link else { return }
            open(place: link)
        }
        .sheet(item: $newTask) { request in
            AddTaskView(due: request.due, projectId: request.projectId, sectionId: request.sectionId, date: request.date)
        }
        .environment(\.calendarDayChanged, { day in calendarDay = day })
        #if os(macOS)
        .frame(minWidth: ZimamLayout.windowMinWidth, minHeight: ZimamLayout.windowMinHeight)
        #endif
    }

    // MARK: iPad and Mac

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(selection: sidebarSelection, onSearch: openSearch)
                .navigationSplitViewColumnWidth(min: ZimamLayout.sidebarMinWidth, ideal: ZimamLayout.sidebarIdealWidth)
        } detail: {
            // A task in the content opens the inspector instead of pushing: a list row selects it
            // through `List(selection:)`, a task in the calendar or the matrix (`TaskOpenLink`),
            // a kanban card and a timeline bar through `\.taskSelection`. The stack's path is
            // always empty, and a route appended to it becomes the selection.
            NavigationStack(path: contentPath) {
                ContentColumn(item: sidebar, searchFocusPending: $searchFocusPending)
                    .environment(\.taskSelection, selectedTask)
                    #if os(macOS)
                    // ⌫ (or Edit › Delete) on the selected task, while the list or the content has
                    // the focus; a text field keeps ⌫ for itself.
                    .onDeleteCommand(perform: selectedTask.wrappedValue == nil ? nil : { confirmingDelete = true })
                    #endif
            }
            .confirmationDialog("حذف المهمة؟", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("حذف", role: .destructive, action: deleteSelected)
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("تُحذف معها مهامها الفرعية وتذكيراتها.")
            }
            .inspector(isPresented: inspectorShown) {
                TaskInspector(route: selectedTask.wrappedValue, onToggleDone: toggleSelectedDone) {
                    selectedTaskId = ""
                }
                .inspectorColumnWidth(min: ZimamLayout.detailColumnMinWidth,
                                      ideal: ZimamLayout.listColumnIdealWidth,
                                      max: ZimamLayout.listColumnIdealWidth * 1.5)
            }
        }
    }

    /// The content stack's path: never pushed. A `TaskRoute` a link appends selects that task.
    private var contentPath: Binding<[TaskRoute]> {
        Binding(
            get: { [] },
            set: { routes in
                if let route = routes.last { selectedTask.wrappedValue = route }
            }
        )
    }

    /// The inspector shows while a task is open; closing it (its button, Esc, or the system's
    /// own dismissal on a narrow iPad) clears the selection.
    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { selectedTask.wrappedValue != nil },
            set: { shown in if !shown { selectedTaskId = "" } }
        )
    }

    /// The sidebar's selection as the user changes it: a new place clears the open task.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { sidebar },
            set: { item in
                guard let item, item != sidebar else { return }
                sidebar = item
                selectedTaskId = ""
            }
        )
    }

    private var selectedTask: Binding<TaskRoute?> {
        Binding(
            get: { UUID(uuidString: selectedTaskId).map { TaskRoute(id: $0) } },
            set: { selectedTaskId = $0?.id.uuidString ?? "" }
        )
    }

    // MARK: iPhone

    private var tabView: some View {
        TabView(selection: $tab) {
            Tab("اليوم", systemImage: "sun.max", value: MainTab.today) {
                NavigationStack(path: $todayPath) { TodayView().compactTaskDestination(selectedTask, path: $todayPath) }
            }
            Tab("القادم", systemImage: "calendar", value: MainTab.upcoming) {
                NavigationStack(path: $upcomingPath) { UpcomingView().compactTaskDestination(selectedTask, path: $upcomingPath) }
            }
            Tab("التقويم", systemImage: "calendar.badge.clock", value: MainTab.calendar) {
                NavigationStack(path: $calendarPath) { CalendarView().compactTaskDestination(selectedTask, path: $calendarPath) }
            }
            Tab("المشاريع", systemImage: "folder", value: MainTab.projects) {
                NavigationStack(path: $projectsPath) { ProjectsView().compactTaskDestination(selectedTask, path: $projectsPath) }
            }
            Tab(value: MainTab.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView(focusPending: $searchFocusPending).compactTaskDestination(selectedTask, path: $searchPath)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .zimamTabBarMinimizes()
        .environment(\.projectOpened, { id in sidebar = .project(id) })
        .environment(\.overviewOpened, { route in sidebar = route.sidebarItem })
    }

    // MARK: Changing width

    /// iPhone layout to the split view: the sidebar follows the tab. On the projects tab it
    /// already names the project opened last (`projectOpened`).
    private func widen() {
        if let item = tab.sidebarItem, sidebar.tab != tab {
            sidebar = item
        }
    }

    /// The split view to the iPhone layout: the tab follows the sidebar, and the open project (or
    /// the inbox, the timeline or the matrix) and task are pushed onto its stack.
    private func narrow() {
        tab = sidebar.tab
        var path = NavigationPath()
        if let project = sidebar.projectId { path.append(project) }
        if let overview = sidebar.overview { path.append(overview) }
        if let route = selectedTask.wrappedValue { path.append(route) }
        switch tab {
        case .today: todayPath = path
        case .upcoming: upcomingPath = path
        case .calendar: calendarPath = path
        case .projects: projectsPath = path
        case .search: searchPath = path
        }
    }

    // MARK: Commands

    private var actions: ZimamSceneActions {
        // Built a step at a time, with each closure's type spelled out: as one expression the
        // compiler failed on it without saying why.
        let newTaskAction: @MainActor () -> Void = { newTask = newTaskRequest() }
        let searchAction: @MainActor () -> Void = { openSearch() }
        var actions = ZimamSceneActions(newTask: newTaskAction, search: searchAction)
        if isRegular && selectedTask.wrappedValue != nil {
            let toggleAction: @MainActor () -> Void = { toggleSelectedDone() }
            actions.toggleSelectedDone = toggleAction
        }
        let syncAction: @MainActor () -> Void = { Task { await sync.sync() } }
        actions.syncNow = syncAction
        return actions
    }

    private func openSearch() {
        if isRegular {
            sidebarSelection.wrappedValue = .search
        } else {
            tab = .search
        }
        searchFocusPending = true
    }

    /// A new task where the user is: due today in «اليوم» and the timeline (a project's timeline
    /// too, so it shows as a bar), tomorrow in «القادم», on the calendar's selected day, in the
    /// open project or section.
    private func newTaskRequest() -> NewTaskRequest {
        // On the iPhone's projects tab, the project (or inbox, timeline, matrix) opened on it
        // names itself in `sidebar` (`projectOpened`, `overviewOpened`).
        let place: SidebarItem = isRegular ? sidebar : (tab.sidebarItem ?? (projectsPath.isEmpty ? .inbox : sidebar))
        switch place {
        case .today, .timeline: return NewTaskRequest(due: .today, projectId: nil)
        case .upcoming: return NewTaskRequest(due: .tomorrow, projectId: nil)
        case .project(let id):
            let descriptor = FetchDescriptor<ProjectItem>(predicate: #Predicate { $0.id == id })
            let layout = (try? context.fetch(descriptor).first)?.layoutRaw
            let due: AddTaskView.Due = layout == ProjectRecord.Layout.timeline.rawValue ? .today : .unscheduled
            return NewTaskRequest(due: due, projectId: id)
        case .section(let id, let section): return NewTaskRequest(due: .unscheduled, projectId: id, sectionId: section)
        case .calendar:
            guard let calendarDay else { return NewTaskRequest(due: .today, projectId: nil) }
            let new = CalendarView.newTask(on: calendarDay, formatter: DualDateFormatter())
            return NewTaskRequest(due: new.due, projectId: nil, date: new.date)
        case .inbox, .matrix, .search: return NewTaskRequest(due: .unscheduled, projectId: nil)
        }
    }

    /// Shows a task's details: in the details column, or on top of the current tab.
    private func open(taskId id: UUID) {
        let route = TaskRoute(id: id)
        if isRegular {
            selectedTask.wrappedValue = route
            return
        }
        switch tab {
        case .today: todayPath.append(route)
        case .upcoming: upcomingPath.append(route)
        case .calendar: calendarPath.append(route)
        case .projects: projectsPath.append(route)
        case .search: searchPath.append(route)
        }
    }

    /// Goes to «اليوم», «التقويم» or «المصفوفة» for a widget link. A day stays pending until
    /// `CalendarView` selects it.
    private func open(place link: AppLink) {
        let item: SidebarItem = switch link {
        case .today, .prayer: .today
        case .matrix: .matrix
        default: .calendar
        }
        if PlaceOpener.shared.pendingDay == nil, link != .prayer {
            PlaceOpener.shared.pending = nil
        }
        if isRegular {
            sidebarSelection.wrappedValue = item
            return
        }
        tab = item.tab
        switch item {
        case .today: todayPath = NavigationPath()
        case .matrix:
            // On the iPhone the matrix sits at the top of the projects tab (`OverviewRoute`).
            var path = NavigationPath()
            path.append(OverviewRoute.matrix)
            projectsPath = path
            sidebar = .matrix
        default: calendarPath = NavigationPath()
        }
    }

    /// Deletes the selected task once confirmed, as «حذف المهمة» in its details, and closes the inspector.
    private func deleteSelected() {
        guard let id = selectedTask.wrappedValue?.id else { return }
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        guard let task = try? context.fetch(descriptor).first, !task.pendingDelete else { return }
        Store(context: context, sync: sync).delete(task)
        selectedTaskId = ""
    }

    private func toggleSelectedDone() {
        guard let id = selectedTask.wrappedValue?.id else { return }
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        guard let task = try? context.fetch(descriptor).first, !task.pendingDelete else { return }
        withAnimation(.zimamComplete) {
            Store(context: context, sync: sync).toggleDone(task)
        }
    }
}

/// What «مهمة جديدة» (⌘N) opens.
struct NewTaskRequest: Identifiable {
    let id = UUID()
    let due: AddTaskView.Due
    let projectId: UUID?
    var sectionId: UUID? = nil
    /// The day a `.pickedDate` opens on: the calendar's selected day.
    var date: Date = Date()
}

/// The middle column for the sidebar's choice.
private struct ContentColumn: View {
    let item: SidebarItem
    @Binding var searchFocusPending: Bool

    var body: some View {
        switch item {
        case .today: TodayView()
        case .upcoming: UpcomingView()
        case .inbox: InboxView()
        case .calendar: CalendarView()
        case .timeline: GanttView(projectId: nil)
        case .matrix: MatrixView()
        case .search: SearchView(focusPending: $searchFocusPending)
        case .project(let id): ProjectDetailView(projectId: id).id(item)
        case .section(let project, let section): ProjectDetailView(projectId: project, sectionId: section).id(item)
        }
    }
}

/// The inspector on the iPad and the Mac: the open task's details in their own stack (so a
/// subtask opens inside it), with «إنجاز» (⌘↩, as the menu's) and «إغلاق» (Esc) in its toolbar.
private struct TaskInspector: View {
    let route: TaskRoute?
    let onToggleDone: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            TaskDetailBody(route: route)
                .taskDetailDestination()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("إغلاق", systemImage: "xmark", action: onClose)
                            .keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if let route {
                            CompleteToolbarButton(taskId: route.id, action: onToggleDone)
                        }
                    }
                }
        }
        // The details' own «إنجاز» gives way to the one above.
        .environment(\.taskCompleteInToolbar, false)
        // A new identity per task for the whole stack: the form loads the newly selected task's
        // fields, and a subtask opened inside it closes with it.
        .id(route?.id)
    }
}

/// The selected task's details; nothing while the inspector closes.
private struct TaskDetailBody: View {
    let route: TaskRoute?

    var body: some View {
        if let route {
            TaskDetailView(taskId: route.id)
        } else {
            ZimamColor.surface
        }
    }
}

/// «إنجاز» or «إلغاء الإنجاز» in the toolbar of a task's details. The inspector passes its own
/// action, whose ⌘↩ is the menu's «إنجاز المهمة المحددة»; elsewhere (the details pushed on the
/// iPhone, where the menu has no selected task) the button completes the task and carries ⌘↩.
struct CompleteToolbarButton: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Query private var matches: [TaskItem]
    let action: (() -> Void)?

    init(taskId: UUID, action: (() -> Void)? = nil) {
        _matches = Query(filter: #Predicate<TaskItem> { $0.id == taskId })
        self.action = action
    }

    var body: some View {
        if let task = matches.first, !task.pendingDelete {
            Button(task.isDone ? "إلغاء الإنجاز" : "إنجاز", systemImage: symbol(done: task.isDone)) {
                if let action {
                    action()
                } else {
                    withAnimation(.zimamComplete) {
                        Store(context: context, sync: sync).toggleDone(task)
                    }
                }
            }
            .zimamProminentToolbarAction()
            .keyboardShortcut(action == nil ? KeyboardShortcut(.return, modifiers: .command) : nil)
        }
    }

    /// The glass toolbar of iOS and macOS 26 already draws the button's shape, so the symbol
    /// drops its circle there (the «none» variant); before 26 it keeps it.
    private func symbol(done: Bool) -> String {
        if #available(iOS 26, macOS 26, *) {
            return done ? "arrow.uturn.backward" : "checkmark"
        }
        return done ? "arrow.uturn.backward.circle" : "checkmark.circle"
    }
}

extension View {
    /// The iPhone's task details, which also remember the open task for the iPad layout.
    /// `path` is the stack's own, to tell a closed task from one only covered.
    func compactTaskDestination(_ selection: Binding<TaskRoute?>, path: Binding<NavigationPath>) -> some View {
        navigationDestination(for: TaskRoute.self) { route in
            CompactTaskDetail(route: route, selection: selection, path: path)
        }
    }
}

/// A task's details pushed on an iPhone tab. Going back (the path got shorter) forgets the task,
/// so a wider window does not open it in the inspector again. A subtask pushed over it, another
/// tab, or the switch to the wide layout only hide it: the path still holds it, and it stays.
private struct CompactTaskDetail: View {
    let route: TaskRoute
    @Binding var selection: TaskRoute?
    @Binding var path: NavigationPath
    @State private var depth = 0

    var body: some View {
        TaskDetailView(taskId: route.id)
            .onAppear {
                selection = route
                depth = path.count
            }
            .onDisappear {
                if path.count < depth, selection == route { selection = nil }
            }
    }
}
