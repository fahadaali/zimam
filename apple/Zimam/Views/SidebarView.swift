import SwiftData
import SwiftUI
import ZimamKit

/// The iPad and Mac sidebar, on the leading side (the right in Arabic): the day views, the
/// inbox, the calendar and search, then the projects with their sections. A task dragged from
/// a list, the board or the calendar onto the inbox, a project or a section moves there
/// (`Store.move(_:toProject:section:)`); «نقل إلى مشروع…» on the task does the same without dragging.
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let onSearch: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// The row a dragged task is over.
    @State private var dropTarget: SidebarItem?

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
                    .modifier(taskDrop(.inbox, name: "صندوق المهام", project: nil, section: nil))
                row("التقويم", systemImage: "calendar.circle", item: .calendar)
                row(OverviewRoute.timeline.title, systemImage: OverviewRoute.timeline.systemImage, item: .timeline)
                row(OverviewRoute.matrix.title, systemImage: OverviewRoute.matrix.systemImage, item: .matrix)
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
                                    .modifier(taskDrop(.section(project: project.id, section: section.id), name: section.name,
                                                         project: project.id, section: section.id))
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
            .modifier(taskDrop(.project(project.id), name: project.name, project: project.id, section: nil))
            .contextMenu {
                Button("مشاركة", systemImage: "person.2") { sharing = ShareTarget(id: project.id) }
            }
    }

    // MARK: Dropping tasks

    private func taskDrop(_ item: SidebarItem, name: String, project: UUID?, section: UUID?) -> SidebarDropTarget {
        SidebarDropTarget(
            isTargeted: dropTarget == item,
            onTargeted: { targeted in
                if targeted {
                    dropTarget = item
                } else if dropTarget == item {
                    dropTarget = nil
                }
            },
            onDrop: { items in moveDropped(items, to: name, project: project, section: section) }
        )
    }

    /// Moves the dropped task. Subtasks follow their parent and are refused on their own.
    private func moveDropped(_ items: [TaskDragItem], to name: String, project: UUID?, section: UUID?) -> Bool {
        dropTarget = nil
        guard let id = items.first?.id,
              let task = tasks.first(where: { $0.id == id }),
              task.parentId == nil else { return false }
        if task.projectId == project && task.sectionId == section { return true }
        withAnimation(reduceMotion ? nil : .default) {
            Store(context: context, sync: sync).move(task, toProject: project, section: section)
        }
        let message: String = "نُقلت «\(task.title)» إلى \(name)"
        AccessibilityNotification.Announcement(message).post()
        return true
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

/// A sidebar row that takes a dropped task, outlined with the focus ring while one is over it.
private struct SidebarDropTarget: ViewModifier {
    let isTargeted: Bool
    let onTargeted: (Bool) -> Void
    let onDrop: ([TaskDragItem]) -> Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
                        .strokeBorder(ZimamColor.focusRing, lineWidth: ZimamLayout.focusRingWidth)
                        .accessibilityHidden(true)
                }
            }
            .dropDestination(for: TaskDragItem.self) { items, _ in
                onDrop(items)
            } isTargeted: { targeted in
                onTargeted(targeted)
            }
    }
}
