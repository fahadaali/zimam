import SwiftData
import SwiftUI
import ZimamKit

struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(SessionStore.self) private var session
    // Kept simple: a compound predicate with two sort keys is too slow for the type checker.
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }, sort: \ProjectItem.sortOrder)
    private var allProjects: [ProjectItem]
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }) private var tasks: [TaskItem]
    @State private var naming = false
    @State private var newName = ""
    @State private var joining = false
    @State private var sharing: ShareTarget?
    @State private var action: ProjectAction?

    init() {}

    private var projects: [ProjectItem] {
        allProjects.filter { $0.kindRaw == "project" && $0.archivedAt == nil }
    }

    private var archived: [ProjectItem] {
        allProjects.filter { $0.kindRaw == "project" && $0.archivedAt != nil }
    }

    var body: some View {
        // Grouped once, then looked up per card, rather than filtering every task per project.
        let byProject = Dictionary(grouping: tasks.filter { $0.parentId == nil }, by: \.projectId)
        List {
            // The timeline and the matrix of every project, at the top of the iPhone's projects tab
            // (the iPad and the Mac list them in the sidebar).
            Section {
                ForEach([OverviewRoute.timeline, .matrix], id: \.self) { route in
                    NavigationLink(value: route) {
                        Label(route.title, systemImage: route.systemImage)
                            .font(ZimamType.body)
                            .foregroundStyle(ZimamColor.ink)
                            .frame(minHeight: ZimamSpacing.space11, alignment: .leading)
                    }
                    .listRowBackground(ZimamColor.surfaceRaised)
                }
            } header: {
                ScreenHeader(title: "المشاريع")
            }
            Section {
                if projects.isEmpty { EmptyLine(text: "لا مشاريع بعد.") }
                ForEach(projects) { project in
                    let own = byProject[project.id] ?? []
                    NavigationLink(value: project.id) {
                        ProjectCard(name: project.name, done: own.filter(\.isDone).count, total: own.count)
                    }
                    .contextMenu {
                        Button("مشاركة", systemImage: "person.2") { sharing = ShareTarget(id: project.id) }
                        if projectPermissions(project, me: session.user?.id).any {
                            Divider()
                            ProjectOptionsItems(project: project, action: $action)
                        }
                    }
                    .projectSwipeActions(project, action: $action)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            ArchivedProjectsSection(projects: archived, action: $action)
        }
        .zimamList()
        .projectActions($action)
        .navigationDestination(for: UUID.self) { ProjectDetailView(projectId: $0) }
        .navigationDestination(for: OverviewRoute.self) { OverviewScreen(route: $0) }
        .toolbar {
            ToolbarItem {
                Button("مشروع جديد", systemImage: "plus") { naming = true }
            }
            ToolbarItem {
                Button("الانضمام بدعوة", systemImage: "person.badge.plus") { joining = true }
            }
        }
        .sheet(isPresented: $joining) { JoinProjectView() }
        .sheet(item: $sharing) { target in ShareProjectView(projectId: target.id) }
        .alert("مشروع جديد", isPresented: $naming) {
            TextField("اسم المشروع", text: $newName)
            Button("إلغاء", role: .cancel) { newName = "" }
            Button("إضافة") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { Store(context: context, sync: sync).addProject(name: name) }
                newName = ""
            }
        }
    }
}

/// The project a share sheet is open for.
struct ShareTarget: Identifiable {
    let id: UUID
}

/// A project's tasks, as a list grouped by section, a kanban board or a timeline («المخطط الزمني»). The choice is the
/// project's `view`, so it is remembered per project and follows it to other devices.
/// From the sidebar a single section opens as a list of its tasks (`sectionId`).
struct ProjectDetailView: View {
    let projectId: UUID
    var sectionId: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.taskSelection) private var taskSelection
    @Environment(\.projectOpened) private var projectOpened
    @Environment(\.projectClosed) private var projectClosed
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sharing = false
    @State private var action: ProjectAction?

    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @Query private var projects: [ProjectItem]
    @Query(filter: #Predicate<SectionItem> { !$0.pendingDelete },
           sort: [SortDescriptor(\SectionItem.sortOrder), SortDescriptor(\SectionItem.createdAt)])
    private var allSections: [SectionItem]
    @State private var showingAdd = false
    /// A board card opened on the iPhone, where the board has no list to select in.
    @State private var opened: TaskRoute?
    /// A task completed in the list stays among the open ones for a second so it can be undone.
    @State private var lingering = Lingering()

    init(projectId: UUID, sectionId: UUID? = nil) {
        self.projectId = projectId
        self.sectionId = sectionId
    }

    private var project: ProjectItem? { projects.first { $0.id == projectId } }
    private var name: String { project?.name ?? "" }
    private var isBoard: Bool {
        sectionId == nil && project?.layoutRaw == ProjectRecord.Layout.kanban.rawValue
    }

    private var isTimeline: Bool {
        sectionId == nil && project?.layoutRaw == ProjectRecord.Layout.timeline.rawValue
    }

    var body: some View {
        let own = tasks.filter { $0.projectId == projectId && $0.parentId == nil }
        let sections = allSections.filter { $0.projectId == projectId }
        Group {
            if isBoard {
                KanbanBoardView(projectId: projectId, title: name, sections: sections,
                                tasks: own, openTask: openTask)
            } else if isTimeline {
                GanttView(projectId: projectId)
            } else {
                list(own: own, sections: sections)
                    .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
            }
        }
        .sheet(isPresented: $showingAdd) { AddTaskView(projectId: projectId) }
        .navigationDestination(item: $opened) { route in TaskDetailView(taskId: route.id) }
        .toolbar {
            ToolbarItem {
                if sectionId == nil, let project {
                    Picker("طريقة العرض", selection: layout(of: project)) {
                        Label("قائمة", systemImage: "list.bullet").tag(ProjectRecord.Layout.list)
                        Label("لوحة", systemImage: "rectangle.split.3x1").tag(ProjectRecord.Layout.kanban)
                        Label("مخطط", systemImage: OverviewRoute.timeline.systemImage).tag(ProjectRecord.Layout.timeline)
                    }
                    .pickerStyle(.segmented)
                }
            }
            ToolbarItem {
                Button("مشاركة", systemImage: "person.2") { sharing = true }
            }
            ToolbarItem {
                if sectionId == nil, let project, projectPermissions(project, me: session.user?.id).any {
                    Menu("خيارات المشروع", systemImage: "ellipsis.circle") {
                        ProjectOptionsItems(project: project, action: $action, onArchived: close)
                    }
                }
            }
        }
        .projectActions($action, onDeleted: close)
        // Leaving the project closes this screen too; its tasks leave with the next pull.
        .sheet(isPresented: $sharing) { ShareProjectView(projectId: projectId, onLeft: { dismiss() }) }
        .onAppear { projectOpened?(projectId) }
    }

    @ViewBuilder
    private func list(own: [TaskItem], sections: [SectionItem]) -> some View {
        let known = Set(sections.map(\.id))
        let shown = own.filter { task in
            guard let sectionId else { return true }
            return task.sectionId == sectionId
        }
        let open = shown.filter { !$0.isDone || lingering.contains($0.id) }
        let done = shown.filter { $0.isDone && !lingering.contains($0.id) }
        List(selection: taskSelection) {
            if let sectionId {
                Section {
                    if open.isEmpty { EmptyLine(text: "لا مهام مفتوحة في هذا القسم.") }
                    ForEach(open) { TaskListItem(task: $0, onCompleted: linger) }
                } header: {
                    ScreenHeader(title: sections.first { $0.id == sectionId }?.name ?? name, subtitle: name)
                }
            } else {
                // Tasks with no section (or one deleted elsewhere) first, then each section.
                Section {
                    if open.isEmpty { EmptyLine(text: "لا مهام مفتوحة في هذا المشروع.") }
                    ForEach(open.filter { $0.sectionId.map { !known.contains($0) } ?? true }) { TaskListItem(task: $0, onCompleted: linger) }
                } header: {
                    ScreenHeader(title: name)
                }
                ForEach(sections) { section in
                    let items = open.filter { $0.sectionId == section.id }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { TaskListItem(task: $0, onCompleted: linger) }
                        } header: {
                            ListSectionHeader(title: section.name)
                        }
                    }
                }
            }
            if !done.isEmpty {
                Section {
                    ForEach(done) { TaskListItem(task: $0) }
                } header: {
                    ListSectionHeader(title: "المنجزة", muted: true)
                }
            }
        }
        .zimamList()
    }

    private func layout(of project: ProjectItem) -> Binding<ProjectRecord.Layout> {
        Binding(
            get: {
                switch ProjectRecord.Layout(rawValue: project.layoutRaw) {
                case .kanban?: .kanban
                case .timeline?: .timeline
                default: .list
                }
            },
            set: { Store(context: context, sync: sync).setLayout(project, $0) }
        )
    }

    /// Opens a board card: in the details column on the iPad and the Mac, pushed on the iPhone.
    private func openTask(_ taskId: UUID) {
        if let taskSelection {
            taskSelection.wrappedValue = TaskRoute(id: taskId)
        } else {
            opened = TaskRoute(id: taskId)
        }
    }

    /// Deleted or archived from here: back to the projects on the iPhone, to the inbox in the sidebar.
    private func close() {
        projectClosed?(projectId)
        dismiss()
    }

    private func linger(_ id: UUID) {
        lingering.hold(id, animation: .zimam(reduceMotion: reduceMotion))
    }
}

/// A section's name over its tasks in a list.
struct ListSectionHeader: View {
    let title: String
    var muted = false

    var body: some View {
        Text(title)
            .font(ZimamType.headline)
            .foregroundStyle(muted ? ZimamColor.inkMuted : ZimamColor.ink)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}
