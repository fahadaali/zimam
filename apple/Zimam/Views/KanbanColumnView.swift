import SwiftData
import SwiftUI
import ZimamKit

/// One kanban column: the name and count, the cards, and «إضافة مهمة» at the bottom.
struct KanbanColumnView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    @State private var isTargeted = false
    @State private var targetedCard: UUID?
    /// Each card's height, for the gap that opens above it.
    @State private var cardHeights: [UUID: CGFloat] = [:]
    /// The card whose «نقل إلى مشروع…» sheet is open.
    @State private var movingToProject: ProjectMoveRequest?
    /// The cards' full height, which caps the scroll view so the column hugs them.
    @State private var cardsHeight: CGFloat?

    private var store: Store { Store(context: context, sync: sync) }

    init(column: BoardColumn, projectId: UUID, previous: BoardColumn?, next: BoardColumn?, destinations: [BoardColumn],
         canMoveEarlier: Bool, canMoveLater: Bool, lookup: @escaping (UUID) -> TaskItem?,
         openTask: @escaping (UUID) -> Void, onCompleted: @escaping (UUID) -> Void,
         onRename: @escaping (SectionItem) -> Void) {
        self.column = column
        self.projectId = projectId
        self.previous = previous
        self.next = next
        self.destinations = destinations
        self.canMoveEarlier = canMoveEarlier
        self.canMoveLater = canMoveLater
        self.lookup = lookup
        self.openTask = openTask
        self.onCompleted = onCompleted
        self.onRename = onRename
    }

    /// The cards, the drop gap and «إضافة مهمة», inside the column's scroll view.
    private var cards: some View {
        VStack(spacing: ZimamSpacing.space2) {
            ForEach(Array(column.tasks.enumerated()), id: \.element.id) { index, task in
                card(task, at: index)
            }
            // Dropped below the last card: the gap opens at the bottom.
            if isTargeted && targetedCard == nil {
                KanbanDropGap(height: column.tasks.last.flatMap { cardHeights[$0.id] } ?? ZimamSpacing.space11)
            }
            KanbanAddTaskControl(column: column, projectId: projectId)
        }
        .animation(.zimam(reduceMotion: reduceMotion), value: targetedCard)
        .animation(.zimam(reduceMotion: reduceMotion), value: isTargeted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            KanbanColumnHeader(column: column, canMoveEarlier: canMoveEarlier, canMoveLater: canMoveLater,
                               onRename: onRename)
            // The column is as tall as its cards, and scrolls only once they outgrow the screen.
            // One scroll view, so «إضافة مهمة» keeps its field and focus when the column crosses that height.
            ScrollView(.vertical) {
                cards
                    .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
                        cardsHeight = height
                    }
            }
            .frame(maxHeight: cardsHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(ZimamSpacing.space3)
        .frame(width: ZimamLayout.kanbanColumnWidth)
        .background(ZimamColor.surfaceSunken, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusLg)
                    .strokeBorder(ZimamColor.focusRing, lineWidth: ZimamLayout.focusRingWidth)
            }
        }
        // Dropped on the column outside the cards: to the bottom.
        .taskDropDestination { items in
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

    // MARK: Cards

    private func card(_ task: TaskItem, at index: Int) -> some View {
        // Where the dragged card will land: a gap opens above this one. The gap is part of the
        // drop target, so the card moving down under the finger does not close it again.
        VStack(spacing: ZimamSpacing.space2) {
            if targetedCard == task.id { KanbanDropGap(height: cardHeights[task.id] ?? ZimamSpacing.space11) }
            KanbanCard(task: task, onToggle: { toggle(task) }, onOpen: { openTask(task.id) })
                .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
                    cardHeights[task.id] = height
                }
                .contextMenu {
                    Button(task.isDone ? "إلغاء الإنجاز" : "إنجاز", systemImage: "checkmark.circle") { toggle(task) }
                    Menu("نقل إلى") {
                        ForEach(destinations) { destination in
                            Button(destination.name) { moveToEnd(task, of: destination) }
                        }
                    }
                    Button("نقل إلى مشروع…", systemImage: "folder") { moveToProject(task) }
                    Button("حذف", systemImage: "trash", role: .destructive) { delete(task) }
                }
                // Dragging is not accessible: the same moves as VoiceOver actions.
                .accessibilityActions {
                    if let next {
                        Button("نقل إلى القسم التالي") { moveToEnd(task, of: next) }
                    }
                    if let previous {
                        Button("نقل إلى القسم السابق") { moveToEnd(task, of: previous) }
                    }
                    if index > 0 {
                        Button("نقل لأعلى") { move(task, to: column, at: index - 1) }
                    }
                    if index + 1 < column.tasks.count {
                        Button("نقل لأسفل") { move(task, to: column, at: index + 1) }
                    }
                    Button("نقل إلى مشروع…") { moveToProject(task) }
                }
        }
        .taskDropDestination { items in
            drop(items, before: task)
        } isTargeted: { targeted in
            setTargeted(targeted, card: task)
        }
    }

    // MARK: Actions

    /// While a card is dragged over this one, the gap opens above it.
    private func setTargeted(_ targeted: Bool, card task: TaskItem) {
        if targeted {
            targetedCard = task.id
        } else if targetedCard == task.id {
            targetedCard = nil
        }
    }

    private func moveToEnd(_ task: TaskItem, of destination: BoardColumn) {
        move(task, to: destination, at: destination.tasks.count)
    }

    private func moveToProject(_ task: TaskItem) {
        movingToProject = ProjectMoveRequest(id: task.id)
    }

    private func delete(_ task: TaskItem) {
        store.delete(task)
    }

    /// `index` counts places in the destination without the task.
    private func move(_ task: TaskItem, to destination: BoardColumn, at index: Int) {
        let changesColumn = destination.id != column.id
        withAnimation(.zimam(reduceMotion: reduceMotion)) {
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
        withAnimation(.zimamComplete) {
            store.toggleDone(task)
        }
        if task.isDone { onCompleted(task.id) }
    }
}
