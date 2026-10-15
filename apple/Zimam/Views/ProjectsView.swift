import SwiftData
import SwiftUI
import ZimamKit

struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    // Kept simple: a compound predicate with two sort keys is too slow for the type checker.
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }, sort: \ProjectItem.sortOrder)
    private var allProjects: [ProjectItem]
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }) private var tasks: [TaskItem]
    @State private var naming = false
    @State private var newName = ""
    @State private var joining = false
    @State private var sharing: ShareTarget?

    init() {}

    private var projects: [ProjectItem] {
        allProjects.filter { $0.kindRaw == "project" }
    }

    var body: some View {
        List {
            Section {
                if projects.isEmpty { EmptyLine(text: "لا مشاريع بعد.") }
                ForEach(projects) { project in
                    let own = tasks.filter { $0.projectId == project.id && $0.parentId == nil }
                    NavigationLink(value: project.id) {
                        ProjectCard(name: project.name, done: own.filter(\.isDone).count, total: own.count)
                    }
                    .contextMenu {
                        Button("مشاركة", systemImage: "person.2") { sharing = ShareTarget(id: project.id) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } header: {
                ScreenHeader(title: "المشاريع")
            }
        }
        .zimamList()
        .navigationDestination(for: UUID.self) { ProjectDetailView(projectId: $0) }
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

struct ProjectDetailView: View {
    let projectId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @Query private var projects: [ProjectItem]
    @State private var showingAdd = false

    private var name: String { projects.first { $0.id == projectId }?.name ?? "" }

    var body: some View {
        let own = tasks.filter { $0.projectId == projectId && $0.parentId == nil }
        let open = own.filter { !$0.isDone }
        let done = own.filter(\.isDone)
        List {
            Section {
                if open.isEmpty { EmptyLine(text: "لا مهام مفتوحة في هذا المشروع.") }
                ForEach(open) { TaskListItem(task: $0) }
            } header: {
                ScreenHeader(title: name)
            }
            if !done.isEmpty {
                Section {
                    ForEach(done) { TaskListItem(task: $0) }
                } header: {
                    Text("المنجزة")
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .textCase(nil)
                }
            }
        }
        .zimamList()
        .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
        .sheet(isPresented: $showingAdd) { AddTaskView(projectId: projectId) }
        .toolbar {
            ToolbarItem {
                Button("مشاركة", systemImage: "person.2") { sharing = true }
            }
        }
        // Leaving the project closes this screen too; its tasks leave with the next pull.
        .sheet(isPresented: $sharing) { ShareProjectView(projectId: projectId, onLeft: { dismiss() }) }
    }
}
