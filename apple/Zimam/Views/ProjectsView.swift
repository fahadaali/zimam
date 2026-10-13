import SwiftData
import SwiftUI
import ZimamKit

struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete && $0.kindRaw == "project" },
           sort: [SortDescriptor(\ProjectItem.sortOrder), SortDescriptor(\ProjectItem.createdAt)])
    private var projects: [ProjectItem]
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }) private var tasks: [TaskItem]
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                if projects.isEmpty { EmptyLine(text: "لا مشاريع بعد.") }
                ForEach(projects) { project in
                    let own = tasks.filter { $0.projectId == project.id && $0.parentId == nil }
                    NavigationLink(value: project.id) {
                        ProjectCard(name: project.name, done: own.filter(\.isDone).count, total: own.count)
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
        }
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

struct ProjectDetailView: View {
    let projectId: UUID

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
    }
}
