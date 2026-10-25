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
    /// Set by an add from Return: iOS gives up the field's focus after Return, and that loss then
    /// brings the keyboard back for the next card instead of closing the field. It holds only for a
    /// moment and for one loss, so a later tap elsewhere still closes the empty field. Typing clears it.
    @State private var refocusUntil: ContinuousClock.Instant?

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
                .onChange(of: newTitle) { _, title in
                    if !title.isEmpty { refocusUntil = nil }
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

    /// Leaving an empty field closes it; a typed title is kept. Return after an add keeps it open.
    private func focusChanged(_ focused: Bool) {
        if !focused, let until = refocusUntil {
            refocusUntil = nil
            if ContinuousClock.now < until {
                fieldFocused = true
                return
            }
        }
        if !focused && newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { adding = false }
    }

    /// Adds the card and keeps the field for the next one. Return on an empty field adds nothing,
    /// so it still closes the field as before.
    private func addTask() {
        let title = newTitle
        newTitle = ""
        let added = withAnimation(.zimam(reduceMotion: reduceMotion)) {
            store.addTask(title: title, projectId: projectId, sectionId: column.section?.id, below: column.tasks)
        }
        guard added != nil else { return }
        #if os(iOS)
        refocusUntil = ContinuousClock.now.advanced(by: .milliseconds(500))
        #endif
        fieldFocused = true
    }
}

/// A task on the board: the task row in its compact form on a raised card, in brand-soft while it
/// is open in the inspector (iPad and Mac). Tapping opens the task; the completion circle completes it.
/// VoiceOver hears it as one element: the title, then what the row shows (date, time, priority).
struct KanbanCard: View {
    let task: TaskItem
    let onToggle: () -> Void
    let onOpen: () -> Void

    @Environment(\.taskSelection) private var taskSelection
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.prayerScheduleZimam) private var schedule

    var body: some View {
        let selected = taskSelection?.wrappedValue?.id == task.id
        TaskRow(task: task, compact: true, selected: selected, onToggle: onToggle)
            .padding(.horizontal, ZimamSpacing.space3)
            .padding(.vertical, ZimamSpacing.space1)
            .background(selected ? ZimamColor.brandSoft : ZimamColor.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .contentShape(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .onTapGesture(perform: onOpen)
            .draggable(TaskDragItem(id: task.id)) { TaskDragPreview(title: task.title) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(task.title)
            .accessibilityValue(spokenDetails)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, onOpen)
            .accessibilityAction(named: task.isDone ? "إلغاء الإنجاز" : "إنجاز", onToggle)
    }

    /// What `TaskRow` shows under and beside the title, in the words its chips speak in a list.
    private var spokenDetails: String {
        var parts: [String] = []
        if task.isDone { parts.append("منجزة") }
        if let notes = task.notes, !notes.isEmpty { parts.append(notes) }
        let now = DayClock.shared.now
        if let date = task.dueDate.flatMap(formatter.date(fromDay:)) {
            let label = formatter.label(for: date, now: now)
            let overdue = !task.isDone && date < Calendar.current.startOfDay(for: now)
            parts.append(overdue ? "\(label)، متأخرة" : label)
        }
        let mode = task.timeMode
        let time = TaskTiming.shownTime(of: mode, dueDay: task.dueDate, schedule: schedule, formatter: formatter)
        switch mode {
        case .allDay:
            break
        case .clock:
            if let time { parts.append(formatter.time(time)) }
        case .prayer(let prayer, let offset):
            let phrase = PrayerPhrase.text(prayer, offsetMinutes: offset, locale: formatter.locale)
            parts.append(time.map { "\(formatter.time($0))، \(phrase)" } ?? phrase)
        }
        if let priority = task.priority.spokenLabel { parts.append(priority) }
        return parts.joined(separator: "، ")
    }
}
