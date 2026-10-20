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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let projectId: UUID
    let title: String
    /// The project's sections in board order.
    let sections: [SectionItem]
    /// The project's top-level tasks in order; the board shows the open ones.
    let tasks: [TaskItem]
    let openTask: (UUID) -> Void

    @State private var lingering = Lingering()
    @State private var addingSection = false
    @State private var sectionName = ""
    @State private var renaming: SectionItem?

    private var store: Store { Store(context: context, sync: sync) }

    /// Every column in board order, «بلا قسم» first. Moves to the next or previous column step through these.
    private var columns: [BoardColumn] {
        let visible = tasks.filter { !$0.isDone || lingering.contains($0.id) }
        let known = Set(sections.map(\.id))
        let loose = visible.filter { $0.sectionId.map { !known.contains($0) } ?? true }
        let bySection = Dictionary(grouping: visible, by: \.sectionId)
        return [BoardColumn(section: nil, tasks: loose)]
            + sections.map { section in BoardColumn(section: section, tasks: bySection[section.id] ?? []) }
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

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    init(projectId: UUID, title: String, sections: [SectionItem], tasks: [TaskItem], openTask: @escaping (UUID) -> Void) {
        self.projectId = projectId
        self.title = title
        self.sections = sections
        self.tasks = tasks
        self.openTask = openTask
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
                            lookup: boardTask(withId:),
                            openTask: openTask,
                            onCompleted: linger,
                            onRename: beginRename
                        )
                    }
                    KanbanAddSectionButton { addingSection = true }
                }
                // Each column snaps into place; the next one peeks in at the edge as the cue to scroll.
                .scrollTargetLayout()
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, gutter)
                .padding(.bottom, gutter)
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .background(ZimamColor.surface)
        .alert("إضافة قسم", isPresented: $addingSection) {
            TextField("اسم القسم", text: $sectionName)
            Button("إلغاء", role: .cancel, action: clearName)
            Button("إضافة", action: addSection)
        }
        .alert("تسمية القسم", isPresented: isRenaming, presenting: renaming) { section in
            TextField("اسم القسم", text: $sectionName)
            Button("إلغاء", role: .cancel, action: clearName)
            Button("حفظ") { rename(section) }
        }
    }

    // MARK: Actions

    private func boardTask(withId id: UUID) -> TaskItem? {
        tasks.first(where: { $0.id == id })
    }

    private func beginRename(_ section: SectionItem) {
        sectionName = section.name
        renaming = section
    }

    private func addSection() {
        store.addSection(named: sectionName, to: projectId)
        sectionName = ""
    }

    private func rename(_ section: SectionItem) {
        store.rename(section, to: sectionName)
        sectionName = ""
    }

    private func clearName() {
        sectionName = ""
    }

    /// A completed card stays for a second so it can be undone, then leaves the board.
    private func linger(_ id: UUID) {
        lingering.hold(id, animation: .zimam(reduceMotion: reduceMotion))
    }
}

/// «إضافة قسم» after the last column, as wide as a column.
private struct KanbanAddSectionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
}
