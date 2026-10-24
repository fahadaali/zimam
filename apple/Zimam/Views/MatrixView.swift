import SwiftData
import SwiftUI
import ZimamKit

/// «المصفوفة»: the open top-level tasks in four quadrants, two by two. Important is a medium or
/// high priority; urgent is due today or tomorrow, or overdue (`PriorityQuadrant`). In Arabic
/// «مهم وعاجل» is at the top right and «يوماً ما» at the bottom left.
///
/// A task completes in place, opens with a tap, and moves to another quadrant by dragging it there
/// or with «نقل إلى» in its menu (and VoiceOver's actions). What a move changes follows
/// `PriorityMatrix.move`: the priority becomes medium (or low) as needed, and the due day becomes
/// today, or is cleared when only a plain day is lost; otherwise the move is refused with a reason.
struct MatrixView: View {
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete },
           sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]

    /// Tasks completed here stay a second, so the completion can be undone.
    @State private var lingering = Lingering()
    @State private var targeted: PriorityQuadrant?
    @State private var refusal: String?
    @State private var showingAdd = false

    // MARK: State

    private var refusalShown: Binding<Bool> {
        Binding(get: { refusal != nil }, set: { shown in if !shown { refusal = nil } })
    }

    private var isRegular: Bool {
        #if os(iOS)
        return horizontalSizeClass == .regular
        #else
        return true
        #endif
    }

    /// Two by two, except on the iPhone at the accessibility text sizes, where a column reads better.
    private var twoColumns: Bool { isRegular || !dynamicTypeSize.isAccessibilitySize }

    private var margin: CGFloat { isRegular ? ZimamSpacing.space6 : ZimamSpacing.space4 }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        return calendar
    }

    private var today: String { formatter.dayString(from: DayClock.shared.now) }

    init() {}

    var body: some View {
        let grouped = PriorityMatrix.group(tasks.filter { $0.parentId == nil }, today: DayClock.shared.now,
                                           calendar: calendar,
                                           isOpen: { !$0.isDone || lingering.contains($0.id) },
                                           priority: \.priority, dueDate: \.dueDate)
        let names = projectNames(projects)
        ScrollView {
            VStack(alignment: .leading, spacing: ZimamSpacing.space4) {
                ScreenHeader(title: OverviewRoute.matrix.title,
                             subtitle: "المهم أولويته متوسطة أو عالية، والعاجل موعده اليوم أو غداً أو فات.")
                if twoColumns {
                    Grid(horizontalSpacing: ZimamSpacing.space3, verticalSpacing: ZimamSpacing.space3) {
                        GridRow {
                            card(.urgentImportant, grouped, names)
                            card(.important, grouped, names)
                        }
                        GridRow {
                            card(.urgent, grouped, names)
                            card(.someday, grouped, names)
                        }
                    }
                } else {
                    VStack(spacing: ZimamSpacing.space3) {
                        ForEach(PriorityQuadrant.allCases) { card($0, grouped, names) }
                    }
                }
            }
            .padding(.horizontal, margin)
            // Room for the add button over the last card.
            .padding(.bottom, ZimamSpacing.space11 + ZimamSpacing.space8)
        }
        .background(ZimamColor.surface)
        .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
        .sheet(isPresented: $showingAdd) { AddTaskView() }
        .alert("لم تُنقل المهمة", isPresented: refusalShown) {
            Button("إغلاق", role: .cancel) { refusal = nil }
        } message: {
            Text(refusal ?? "")
        }
    }

    private func card(_ quadrant: PriorityQuadrant, _ grouped: [PriorityQuadrant: [TaskItem]], _ names: [UUID: String]) -> some View {
        QuadrantCard(quadrant: quadrant, tasks: grouped[quadrant] ?? [], names: names, today: today,
                     isTargeted: targeted == quadrant,
                     onToggle: complete,
                     onMove: { task, target in move(task, to: target) },
                     onDrop: { ids in drop(ids, on: quadrant) },
                     onTargeted: { on in setTargeted(on, quadrant: quadrant) })
    }

    // MARK: Actions

    /// The quadrant a dragged task is over, outlined until the drag leaves it.
    private func setTargeted(_ on: Bool, quadrant: PriorityQuadrant) {
        if on {
            targeted = quadrant
        } else if targeted == quadrant {
            targeted = nil
        }
    }

    private func complete(_ task: TaskItem) {
        withAnimation(.zimamComplete) { Store(context: context, sync: sync).toggleDone(task) }
        if task.isDone { lingering.hold(task.id, animation: .zimam(reduceMotion: reduceMotion)) }
    }

    private func drop(_ ids: [UUID], on quadrant: PriorityQuadrant) -> Bool {
        targeted = nil
        guard let id = ids.first, let task = tasks.first(where: { $0.id == id && $0.parentId == nil }) else { return false }
        move(task, to: quadrant)
        return true
    }

    private func move(_ task: TaskItem, to quadrant: PriorityQuadrant) {
        let result = withAnimation(.zimam(reduceMotion: reduceMotion)) {
            Store(context: context, sync: sync).move(task, to: quadrant, timeZone: formatter.timeZone)
        }
        switch result {
        case .moved:
            let message: String = "نُقلت «\(task.title)» إلى «\(quadrant.title)»"
            AccessibilityNotification.Announcement(message).post()
        case .refused:
            refusal = "«\(task.title)» لها وقت أو صلاة أو تكرار أو تاريخ بداية أو تذكير مرتبط بموعدها. غيّر موعدها من تفاصيلها لتخرج من العاجل."
        case .unchanged:
            break
        }
    }
}

extension PriorityQuadrant {
    /// The quadrant's color, never alone: its name and icon go with it.
    var color: Color {
        switch self {
        case .urgentImportant: ZimamColor.quadrantUrgentImportant
        case .important: ZimamColor.quadrantImportant
        case .urgent: ZimamColor.quadrantUrgent
        case .someday: ZimamColor.quadrantSomeday
        }
    }

    var systemImage: String {
        switch self {
        case .urgentImportant: "flame"
        case .important: "calendar"
        case .urgent: "bolt"
        case .someday: "line.3.horizontal"
        }
    }
}

/// The inbox, the timeline or the matrix pushed on the iPhone's projects tab.
struct OverviewScreen: View {
    let route: OverviewRoute

    @Environment(\.overviewOpened) private var overviewOpened

    var body: some View {
        Group {
            switch route {
            case .inbox: InboxView()
            case .timeline: GanttView(projectId: nil)
            case .matrix: MatrixView()
            }
        }
        .onAppear { overviewOpened?(route) }
    }
}
