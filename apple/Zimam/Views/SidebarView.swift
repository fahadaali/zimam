import SwiftData
import SwiftUI
import ZimamKit

/// The iPad and Mac sidebar, on the leading side (the right in Arabic): the day views, the
/// inbox, the calendar and search, then the projects with their sections.
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let onSearch: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dateFormatterZimam) private var formatter

    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }, sort: \ProjectItem.sortOrder)
    private var allProjects: [ProjectItem]
    @Query(filter: #Predicate<SectionItem> { !$0.pendingDelete },
           sort: [SortDescriptor(\SectionItem.sortOrder), SortDescriptor(\SectionItem.createdAt)])
    private var sections: [SectionItem]
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }) private var tasks: [TaskItem]

    @State private var expanded: Set<UUID> = []
    @State private var naming = false
    @State private var newName = ""
    @State private var joining = false
    @State private var sharing: ShareTarget?

    init(selection: Binding<SidebarItem?>, onSearch: @escaping () -> Void) {
        _selection = selection
        self.onSearch = onSearch
    }

    private var projects: [ProjectItem] {
        allProjects.filter { $0.kindRaw == "project" }
    }

    var body: some View {
        let open = tasks.filter { !$0.isDone && $0.parentId == nil }
        let today = formatter.dayString(from: Date())
        List(selection: $selection) {
            Section {
                row("اليوم", systemImage: "sun.max", item: .today,
                    count: open.filter { $0.dueDate.map { $0 <= today } ?? false }.count)
                row("القادم", systemImage: "calendar", item: .upcoming)
                row("صندوق المهام", systemImage: "tray", item: .inbox,
                    count: open.filter { $0.projectId == nil }.count)
                row("التقويم", systemImage: "calendar.circle", item: .calendar)
                row("البحث", systemImage: "magnifyingglass", item: .search)
            }

            Section("المشاريع") {
                if projects.isEmpty {
                    Text("لا مشاريع بعد.")
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                ForEach(projects) { project in
                    let own = sections.filter { $0.projectId == project.id }
                    let count = open.filter { $0.projectId == project.id }.count
                    if own.isEmpty {
                        projectRow(project, count: count)
                    } else {
                        DisclosureGroup(isExpanded: expansion(of: project.id)) {
                            ForEach(own) { section in
                                row(section.name, systemImage: "rectangle.split.3x1",
                                    item: .section(project: project.id, section: section.id),
                                    count: open.filter { $0.sectionId == section.id }.count)
                            }
                        } label: {
                            projectRow(project, count: count)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surfaceSunken)
        .navigationTitle("زمام")
        .toolbar {
            ToolbarItem {
                Button("مشروع جديد", systemImage: "folder.badge.plus") { naming = true }
            }
            ToolbarItem {
                Button("الانضمام بدعوة", systemImage: "person.badge.plus") { joining = true }
            }
            ToolbarItem {
                Button("بحث", systemImage: "magnifyingglass", action: onSearch)
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
        .onAppear {
            // A section restored from the last session shows inside its open project.
            if case .section(let project, _) = selection { expanded.insert(project) }
        }
        .sheet(isPresented: $joining) { JoinProjectView() }
        .sheet(item: $sharing) { target in ShareProjectView(projectId: target.id) }
        .alert("مشروع جديد", isPresented: $naming) {
            TextField("اسم المشروع", text: $newName)
            Button("إلغاء", role: .cancel) { newName = "" }
            Button("إضافة") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    let project = Store(context: context, sync: sync).addProject(name: name)
                    selection = .project(project.id)
                }
                newName = ""
            }
        }
    }

    private func row(_ title: String, systemImage: String, item: SidebarItem, count: Int = 0) -> some View {
        Label(title, systemImage: systemImage)
            .font(ZimamType.body)
            .badge(count > 0 ? Text(count, format: .number) : nil)
            .frame(minHeight: ZimamSpacing.space11)
            .tag(item)
    }

    private func projectRow(_ project: ProjectItem, count: Int) -> some View {
        row(project.name, systemImage: "folder", item: .project(project.id), count: count)
            .contextMenu {
                Button("مشاركة", systemImage: "person.2") { sharing = ShareTarget(id: project.id) }
            }
    }

    private func expansion(of projectId: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(projectId) },
            set: { isOpen in
                if isOpen { expanded.insert(projectId) } else { expanded.remove(projectId) }
            }
        )
    }
}
