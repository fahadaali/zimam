import SwiftData
import SwiftUI
import ZimamKit

/// The opened place where a dragged card will land, outlined in the focus ring colour
/// (design/README.md «الحالات والحركة»). SwiftUI does not say which card is being dragged until
/// it is dropped, so the gap takes the height of the card it opens above; cards in a column share
/// one layout, so that is the dragged card's height in all but unusual cases.
struct KanbanDropGap: View {
    var height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
            .strokeBorder(ZimamColor.focusRing, lineWidth: ZimamLayout.focusRingWidth)
            .frame(height: height)
            .transition(.opacity)
            .accessibilityHidden(true)
    }
}

/// A column's name and count, and a section's menu.
struct KanbanColumnHeader: View {
    @Environment(\.locale) private var locale

    let column: BoardColumn
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let onRename: (SectionItem) -> Void

    var body: some View {
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
                KanbanSectionMenu(section: section, canMoveEarlier: canMoveEarlier, canMoveLater: canMoveLater,
                                  onRename: onRename)
            }
        }
        .frame(minHeight: ZimamSpacing.space11)
        .padding(.leading, ZimamSpacing.space1)
    }
}

/// A section's menu: rename, move earlier or later, and delete after asking.
struct KanbanSectionMenu: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync

    let section: SectionItem
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let onRename: (SectionItem) -> Void

    @State private var confirmingDelete = false

    private var store: Store { Store(context: context, sync: sync) }

    init(section: SectionItem, canMoveEarlier: Bool, canMoveLater: Bool, onRename: @escaping (SectionItem) -> Void) {
        self.section = section
        self.canMoveEarlier = canMoveEarlier
        self.canMoveLater = canMoveLater
        self.onRename = onRename
    }

    var body: some View {
        Menu {
            Button("إعادة التسمية", systemImage: "pencil") { onRename(section) }
            if canMoveEarlier {
                Button("تقديم القسم") { moveSection(by: -1) }
            }
            if canMoveLater {
                Button("تأخير القسم") { moveSection(by: 1) }
            }
            Divider()
            Button("حذف القسم", systemImage: "trash", role: .destructive) { confirmingDelete = true }
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
        // On the menu that asked, so on the iPad the dialog points at the column.
        .confirmationDialog("حذف القسم؟", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("حذف القسم", role: .destructive, action: deleteSection)
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("تبقى مهامه في المشروع بلا قسم.")
        }
    }

    private func moveSection(by offset: Int) {
        store.moveSection(section, by: offset)
    }

    private func deleteSection() {
        store.delete(section)
    }
}

/// «إضافة مهمة» at the bottom of a column, which turns into a title field.
struct KanbanAddTaskControl: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let column: BoardColumn
    let projectId: UUID

    @State private var adding = false
    @State private var newTitle = ""
    @FocusState private var fieldFocused: Bool

    private var store: Store { Store(context: context, sync: sync) }

    init(column: BoardColumn, projectId: UUID) {
        self.column = column
        self.projectId = projectId
    }

    var body: some View {
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
                .onChange(of: fieldFocused) { _, focused in focusChanged(focused) }
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

    /// Leaving an empty field closes it; a typed title is kept.
    private func focusChanged(_ focused: Bool) {
        if !focused && newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { adding = false }
    }

    private func addTask() {
        let title = newTitle
        newTitle = ""
        withAnimation(.zimam(reduceMotion: reduceMotion)) {
            _ = store.addTask(title: title, projectId: projectId, sectionId: column.section?.id, below: column.tasks)
        }
    }
}

/// A task on the board: the task row in its compact form on a raised card.
/// Tapping opens the task; the completion circle completes it.
struct KanbanCard: View {
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
            .draggable(TaskDragItem(id: task.id)) { TaskDragPreview(title: task.title) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(task.title)
            .accessibilityValue(task.isDone ? "منجزة" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onOpen)
            .accessibilityAction(named: task.isDone ? "إلغاء الإنجاز" : "إنجاز", onToggle)
    }
}
