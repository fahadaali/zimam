import SwiftData
import SwiftUI
import ZimamKit

/// The signed-in app. On the iPhone (compact width) the four tabs; on the iPad and the Mac
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
        // A task opened from Siri, Shortcuts or Spotlight (OpenTaskIntent).
        .onChange(of: TaskOpener.shared.pending, initial: true) { _, id in
            guard let id else { return }
            TaskOpener.shared.pending = nil
            open(taskId: id)
        }
        // «اليوم», «التقويم» or a day, opened from a widget (App/AppLinks.swift).
        .onChange(of: PlaceOpener.shared.pending, initial: true) { _, link in
            guard let link else { return }
            open(place: link)
        }
        .sheet(item: $newTask) { request in
            AddTaskView(due: request.due, projectId: request.projectId)
        }
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
            // A task link in the content (a list row, a calendar day, a kanban card) opens the
            // inspector instead of pushing: the stack's path is always empty, and what a link
            // appends becomes the selection.
            NavigationStack(path: contentPath) {
                ContentColumn(item: sidebar)
                    .environment(\.taskSelection, selectedTask)
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
                NavigationStack(path: $todayPath) { TodayView().compactTaskDestination(selectedTask) }
            }
            Tab("القادم", systemImage: "calendar", value: MainTab.upcoming) {
                NavigationStack(path: $upcomingPath) { UpcomingView().compactTaskDestination(selectedTask) }
            }
            Tab("التقويم", systemImage: "calendar.badge.clock", value: MainTab.calendar) {
                NavigationStack(path: $calendarPath) { CalendarView().compactTaskDestination(selectedTask) }
            }
            Tab("المشاريع", systemImage: "folder", value: MainTab.projects) {
                NavigationStack(path: $projectsPath) { ProjectsView().compactTaskDestination(selectedTask) }
            }
            Tab(value: MainTab.search, role: .search) {
                NavigationStack(path: $searchPath) { SearchView().compactTaskDestination(selectedTask) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .zimamTabBarMinimizes()
        .environment(\.projectOpened, { id in sidebar = .project(id) })
        .environment(\.overviewOpened, { route in sidebar = route.sidebarItem })
    }

    // MARK: Changing width

    /// iPhone layout to three columns: the sidebar follows the tab. On the projects tab it
    /// already names the project opened last (`projectOpened`).
    private func widen() {
        if let item = tab.sidebarItem, sidebar.tab != tab {
            sidebar = item
        }
    }

    /// Three columns to the iPhone layout: the tab follows the sidebar, and the open project
    /// and task are pushed onto its stack.
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
        return actions
    }

    private func openSearch() {
        if isRegular {
            sidebarSelection.wrappedValue = .search
        } else {
            tab = .search
        }
    }

    /// A new task where the user is: due today in «اليوم», tomorrow in «القادم», in the open project.
    private func newTaskRequest() -> NewTaskRequest {
        let place: SidebarItem = isRegular ? sidebar : (tab.sidebarItem ?? .inbox)
        switch place {
        case .today: return NewTaskRequest(due: .today, projectId: nil)
        case .upcoming: return NewTaskRequest(due: .tomorrow, projectId: nil)
        case .project(let id), .section(let id, _): return NewTaskRequest(due: .unscheduled, projectId: id)
        case .inbox, .calendar, .timeline, .matrix, .search: return NewTaskRequest(due: .unscheduled, projectId: nil)
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

    /// Goes to «اليوم» or «التقويم» for a widget link. A day stays pending until `CalendarView`
    /// selects it.
    private func open(place link: AppLink) {
        let item: SidebarItem = link == .today || link == .prayer ? .today : .calendar
        if PlaceOpener.shared.pendingDay == nil, link != .prayer {
            PlaceOpener.shared.pending = nil
        }
        if isRegular {
            sidebarSelection.wrappedValue = item
            return
        }
        tab = item.tab
        if item == .today { todayPath = NavigationPath() } else { calendarPath = NavigationPath() }
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
}

/// The middle column for the sidebar's choice.
private struct ContentColumn: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .today: TodayView()
        case .upcoming: UpcomingView()
        case .inbox: InboxView()
        case .calendar: CalendarView()
        case .timeline: GanttView(projectId: nil)
        case .matrix: MatrixView()
        case .search: SearchView()
        case .project(let id): ProjectDetailView(projectId: id).id(item)
        case .section(let project, let section): ProjectDetailView(projectId: project, sectionId: section).id(item)
        }
    }
}

/// The inspector on the iPad and the Mac: the open task's details in their own stack (so a
/// subtask opens inside it), with «إنجاز» (⌘↩) and «إغلاق» (Esc) in its toolbar.
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
    }
}

/// The selected task's details; nothing while the inspector closes.
private struct TaskDetailBody: View {
    let route: TaskRoute?

    var body: some View {
        if let route {
            // A new identity per task, so the form loads the newly selected task's fields.
            TaskDetailView(taskId: route.id).id(route.id)
        } else {
            ZimamColor.surface
        }
    }
}

/// «إنجاز» in the details column's toolbar, with ⌘↩ on the iPad and the Mac.
private struct CompleteToolbarButton: View {
    @Query private var matches: [TaskItem]
    let action: () -> Void

    init(taskId: UUID, action: @escaping () -> Void) {
        _matches = Query(filter: #Predicate<TaskItem> { $0.id == taskId })
        self.action = action
    }

    var body: some View {
        if let task = matches.first, !task.pendingDelete {
            Button(task.isDone ? "إلغاء الإنجاز" : "إنجاز",
                   systemImage: symbol(done: task.isDone),
                   action: action)
                .zimamProminentToolbarAction()
                .keyboardShortcut(.return, modifiers: .command)
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
    func compactTaskDestination(_ selection: Binding<TaskRoute?>) -> some View {
        navigationDestination(for: TaskRoute.self) { route in
            TaskDetailView(taskId: route.id)
                .onAppear { selection.wrappedValue = route }
        }
    }
}
