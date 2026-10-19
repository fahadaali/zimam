import SwiftData
import SwiftUI
import ZimamKit

/// One column of the board: a section, or the project's tasks with no section («بلا قسم»).
struct BoardColumn: Identifiable {
    let section: SectionItem?
    let tasks: [TaskItem]

    var id: String { section?.id.uuidString ?? "unsectioned" }
    var name: String { section?.name ?? "بلا قسم" }
}

/// A project as a kanban board (design/components/KanbanColumn): one column per section,
/// «بلا قسم» first, then «إضافة قسم». The columns follow the layout direction, so in Arabic
/// the first one sits at the right edge and the board scrolls toward the left.
/// Tasks move by drag and drop between and within columns, from the card's menu, and with
/// VoiceOver actions, since dragging is not accessible. Every move goes through `Store`.
struct KanbanBoardView: View {
    let projectId: UUID
    let title: String
    /// The project's sections in board order.
    let sections: [SectionItem]
    /// The project's top-level tasks in order; the board shows the open ones.
    let tasks: [TaskItem]
    let openTask: (UUID) -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var lingering = Lingering()
    @State private var addingSection = false
    @State private var sectionName = ""
    @State private var renaming: SectionItem?
    @State private var deleting: SectionItem?

    init(projectId: UUID, title: String, sections: [SectionItem], tasks: [TaskItem], openTask: @escaping (UUID) -> Void) {
        self.projectId = projectId
        self.title = title
        self.sections = sections
        self.tasks = tasks
        self.openTask = openTask
    }

    private var store: Store { Store(context: context, sync: sync) }

    /// Every column in board order, «بلا قسم» first. Moves to the next or previous column step through these.
    private var columns: [BoardColumn] {
        let visible = tasks.filter { !$0.isDone || lingering.contains($0.id) }
        let known = Set(sections.map(\.id))
        let loose = visible.filter { $0.sectionId.map { !known.contains($0) } ?? true }
        return [BoardColumn(section: nil, tasks: loose)]
            + sections.map { section in BoardColumn(section: section, tasks: visible.filter { $0.sectionId == section.id }) }
    }

    /// The side margin: space-4 on the iPhone, space-6 on the iPad and the Mac (design/README.md).
    private var gutter: CGFloat {
        #if os(iOS)
        return sizeClass == .regular ? ZimamSpacing.space6 : ZimamSpacing.space4
        #else
        return ZimamSpacing.space6
        #endif
    }

    /// Between columns: space-8 on the Mac (tokens.json), less on smaller screens.
    private var columnSpacing: CGFloat {
        #if os(iOS)
        return sizeClass == .regular ? ZimamSpacing.space6 : ZimamSpacing.space4
        #else
        return ZimamSpacing.space8
        #endif
    }

    var body: some View {
        let all = columns
        // «بلا قسم» stays out of the way once sections exist and it is empty; moves can still reach it.
        let shown = all.filter { $0.section != nil || !$0.tasks.isEmpty || sections.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: title)
                .padding(.horizontal, gutter)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(shown) { column in
                        let index = all.firstIndex(where: { $0.id == column.id }) ?? 0
                        KanbanColumnView(
                            column: column,
                            projectId: projectId,
                            previous: index > 0 ? all[index - 1] : nil,
                            next: index + 1 < all.count ? all[index + 1] : nil,
                            destinations: all.filter { $0.id != column.id },
                            canMoveEarlier: column.section != nil && index > 1,
                            canMoveLater: column.section != nil && index + 1 < all.count,
                            lookup: { id in tasks.first(where: { $0.id == id }) },
                            openTask: openTask,
                            onCompleted: linger,
                            onRename: { section in
                                sectionName = section.name
                                renaming = section
                            },
                            onDelete: { section in deleting = section }
                        )
                    }
                    addSectionButton
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, gutter)
                .padding(.bottom, gutter)
            }
        }
        .background(ZimamColor.surface)
        .alert("إضافة قسم", isPresented: $addingSection) {
            TextField("اسم القسم", text: $sectionName)
            Button("إلغاء", role: .cancel) { sectionName = "" }
            Button("إضافة") {
                store.addSection(named: sectionName, to: projectId)
                sectionName = ""
            }
        }
        .alert("تسمية القسم", isPresented: isRenaming, presenting: renaming) { section in
            TextField("اسم القسم", text: $sectionName)
            Button("إلغاء", role: .cancel) { sectionName = "" }
            Button("حفظ") {
                store.rename(section, to: sectionName)
                sectionName = ""
            }
        }
        .confirmationDialog("حذف القسم؟", isPresented: isDeleting, titleVisibility: .visible, presenting: deleting) { section in
            Button("حذف القسم", role: .destructive) { store.delete(section) }
            Button("إلغاء", role: .cancel) {}
        } message: { _ in
            Text("تبقى مهامه في المشروع بلا قسم.")
        }
    }

    private var addSectionButton: some View {
        Button { addingSection = true } label: {
            Label("إضافة قسم", systemImage: "plus")
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.inkMuted)
                .frame(width: ZimamLayout.kanbanColumnWidth)
                .frame(minHeight: ZimamSpacing.space11)
                .padding(.vertical, ZimamSpacing.space3)
                .background(ZimamColor.surfaceSunken, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
                .overlay {
                    RoundedRectangle(cornerRadius: ZimamRadius.radiusLg)
                        .strokeBorder(ZimamColor.lineStrong, style: StrokeStyle(dash: [ZimamSpacing.space1, ZimamSpacing.space1]))
                }
                .contentShape(RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        }
        .buttonStyle(.plain)
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    /// A completed card stays for a second so it can be undone, then leaves the board.
    private func linger(_ id: UUID) {
        lingering.hold(id, animation: reduceMotion ? nil : .default)
    }
}

/// One kanban column: the name and count, the cards, and «إضافة مهمة» at the bottom.
private struct KanbanColumnView: View {
    let column: BoardColumn
    let projectId: UUID
    let previous: BoardColumn?
    let next: BoardColumn?
    /// Every other column, for the card's «نقل إلى» menu.
    let destinations: [BoardColumn]
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    /// Finds a dragged task among the project's tasks; tasks from elsewhere are refused.
    let lookup: (UUID) -> TaskItem?
    let openTask: (UUID) -> Void
    let onCompleted: (UUID) -> Void
    let onRename: (SectionItem) -> Void
    let onDelete: (SectionItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isTargeted = false
    @State private var targetedCard: UUID?
    /// The card whose «نقل إلى مشروع…» sheet is open.
    @State private var movingToProject: ProjectMoveRequest?
    @State private var adding = false
    @State private var newTitle = ""
    @FocusState private var fieldFocused: Bool

    private var store: Store { Store(context: context, sync: sync) }

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            header
            ScrollView(.vertical) {
                VStack(spacing: ZimamSpacing.space2) {
                    ForEach(Array(column.tasks.enumerated()), id: \.element.id) { index, task in
                        card(task, at: index)
                    }
                    addControl
                }
            }
        }
        .padding(ZimamSpacing.space3)
        .frame(width: ZimamLayout.kanbanColumnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ZimamColor.surfaceSunken, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusLg)
                    .strokeBorder(ZimamColor.focusRing, lineWidth: ZimamLayout.focusRingWidth)
            }
        }
        // Dropped on the column outside the cards: to the bottom.
        .dropDestination(for: TaskDragItem.self) { items, _ in
            drop(items, before: nil)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(column.name)
        .sheet(item: $movingToProject) { request in
            MoveToProjectSheet(taskId: request.id)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: ZimamSpacing.space2) {
            HStack(spacing: ZimamSpacing.space2) {
                Text(column.name)
                    .font(ZimamType.headline)
                    .foregroundStyle(ZimamColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(column.tasks.count, format: .number)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .padding(.horizontal, ZimamSpacing.space2)
                    .background(ZimamColor.surfaceRaised, in: Capsule())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(column.name)
            .accessibilityValue(ArabicCount.tasks(column.tasks.count, locale: locale))
            .accessibilityAddTraits(.isHeader)

            if let section = column.section {
                sectionMenu(section)
            }
        }
        .frame(minHeight: ZimamSpacing.space11)
        .padding(.leading, ZimamSpacing.space1)
    }

    private func sectionMenu(_ section: SectionItem) -> some View {
        Menu {
            Button("إعادة التسمية", systemImage: "pencil") { onRename(section) }
            if canMoveEarlier {
                Button("تقديم القسم") { store.moveSection(section, by: -1) }
            }
            if canMoveLater {
                Button("تأخير القسم") { store.moveSection(section, by: 1) }
            }
            Divider()
            Button("حذف القسم", systemImage: "trash", role: .destructive) { onDelete(section) }
        } label: {
            Image(systemName: "ellipsis")
                .font(ZimamType.body)
                .foregroundStyle(ZimamColor.inkMuted)
                .frame(minWidth: ZimamSpacing.space11, minHeight: ZimamSpacing.space11)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("خيارات القسم \(section.name)")
    }

    // MARK: Cards

    private func card(_ task: TaskItem, at index: Int) -> some View {
        KanbanCard(task: task, onToggle: { toggle(task) }, onOpen: { openTask(task.id) })
            // Where the dragged card will land: a line above this one.
            .overlay(alignment: .top) {
                if targetedCard == task.id {
                    Capsule()
                        .fill(ZimamColor.focusRing)
                        .frame(height: ZimamLayout.focusRingWidth)
                        .offset(y: -ZimamSpacing.space1)
                        .accessibilityHidden(true)
                }
            }
            .dropDestination(for: TaskDragItem.self) { items, _ in
                drop(items, before: task)
            } isTargeted: { targeted in
                if targeted {
                    targetedCard = task.id
                } else if targetedCard == task.id {
                    targetedCard = nil
                }
            }
            .contextMenu {
                Button(task.isDone ? "إلغاء الإنجاز" : "إنجاز", systemImage: "checkmark.circle") { toggle(task) }
                Menu("نقل إلى") {
                    ForEach(destinations) { destination in
                        Button(destination.name) { move(task, to: destination, at: destination.tasks.count) }
                    }
                }
                Button("نقل إلى مشروع…", systemImage: "folder") { movingToProject = ProjectMoveRequest(id: task.id) }
                Button("حذف", systemImage: "trash", role: .destructive) { store.delete(task) }
            }
            // Dragging is not accessible: the same moves as VoiceOver actions.
            .accessibilityActions {
                if let next {
                    Button("نقل إلى القسم التالي") { move(task, to: next, at: next.tasks.count) }
                }
                if let previous {
                    Button("نقل إلى القسم السابق") { move(task, to: previous, at: previous.tasks.count) }
                }
                if index > 0 {
                    Button("نقل لأعلى") { move(task, to: column, at: index - 1) }
                }
                if index + 1 < column.tasks.count {
                    Button("نقل لأسفل") { move(task, to: column, at: index + 1) }
                }
                Button("نقل إلى مشروع…") { movingToProject = ProjectMoveRequest(id: task.id) }
            }
    }

    /// `index` counts places in the destination without the task.
    private func move(_ task: TaskItem, to destination: BoardColumn, at index: Int) {
        let changesColumn = destination.id != column.id
        withAnimation(reduceMotion ? nil : .default) {
            store.place(task, inSection: destination.section?.id, at: index, column: destination.tasks)
        }
        if changesColumn {
            let message: String = "نُقلت إلى \(destination.name)"
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private func drop(_ items: [TaskDragItem], before target: TaskItem?) -> Bool {
        targetedCard = nil
        guard let id = items.first?.id, id != target?.id, let task = lookup(id) else { return false }
        let others = column.tasks.filter { $0.id != id }
        let index = target.flatMap { target in others.firstIndex { $0.id == target.id } } ?? others.count
        move(task, to: column, at: index)
        return true
    }

    private func toggle(_ task: TaskItem) {
        withAnimation(reduceMotion ? nil : .default) {
            store.toggleDone(task)
        }
        if task.isDone { onCompleted(task.id) }
    }

    // MARK: Adding

    @ViewBuilder
    private var addControl: some View {
        if adding {
            TextField("عنوان المهمة", text: $newTitle)
                .textFieldStyle(.plain)
                .font(ZimamType.callout)
                .focused($fieldFocused)
                .onSubmit(addTask)
                .padding(.horizontal, ZimamSpacing.space3)
                .frame(minHeight: ZimamSpacing.space11)
                .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
                .overlay {
                    RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
                        .strokeBorder(ZimamColor.lineStrong)
                }
                .onAppear { fieldFocused = true }
                .onChange(of: fieldFocused) { _, focused in
                    // Leaving an empty field closes it; a typed title is kept.
                    if !focused && newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { adding = false }
                }
        } else {
            Button { adding = true } label: {
                Label("إضافة مهمة", systemImage: "plus")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
                    .overlay {
                        RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
                            .strokeBorder(ZimamColor.lineStrong, style: StrokeStyle(dash: [ZimamSpacing.space1, ZimamSpacing.space1]))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إضافة مهمة إلى \(column.name)")
        }
    }

    private func addTask() {
        let title = newTitle
        newTitle = ""
        withAnimation(reduceMotion ? nil : .default) {
            _ = store.addTask(title: title, projectId: projectId, sectionId: column.section?.id, below: column.tasks)
        }
    }
}

/// A task on the board: the task row in its compact form on a raised card.
/// Tapping opens the task; the completion circle completes it.
private struct KanbanCard: View {
    let task: TaskItem
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        TaskRow(task: task, compact: true, onToggle: onToggle)
            .padding(.horizontal, ZimamSpacing.space3)
            .padding(.vertical, ZimamSpacing.space1)
            .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .contentShape(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .onTapGesture(perform: onOpen)
            .draggable(TaskDragItem(id: task.id))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(task.title)
            .accessibilityValue(task.isDone ? "منجزة" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onOpen)
            .accessibilityAction(named: task.isDone ? "إلغاء الإنجاز" : "إنجاز", onToggle)
    }
}
