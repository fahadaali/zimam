import SwiftData
import SwiftUI
import ZimamKit

/// Open tasks due today or overdue, with the assistant's summary of the day on request.
/// A task completed here stays for a second so it can be undone.
struct TodayView: View {
    /// Every sheet this screen opens, so only one is ever up at a time.
    private enum SheetRoute: Identifiable {
        case add
        case prayers
        case event(ShownEvent)

        var id: String {
            switch self {
            case .add: "add"
            case .prayers: "prayers"
            case .event(let item): "event-\(item.id)"
            }
        }
    }

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.taskSelection) private var taskSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]
    @State private var lingering = Lingering()
    /// The one sheet open on this screen: adding a task, «أوقات الصلاة», or the details of an
    /// Apple Calendar event.
    @State private var sheet: SheetRoute?

    private var items: [TaskItem] {
        let today = formatter.dayString(from: Date())
        return tasks
            .filter { task in
                guard task.parentId == nil, let due = task.dueDate, due <= today else { return false }
                return !task.isDone || lingering.contains(task.id)
            }
            .sorted { ($0.dueDate ?? "", $0.dueTime ?? "") < ($1.dueDate ?? "", $1.dueTime ?? "") }
    }

    private var todayEvents: [ShownEvent] {
        let today = formatter.dayString(from: Date())
        return CalendarEvents.shared.events(from: today, to: today, timeZone: formatter.timeZone)
    }

    var body: some View {
        let names = projectNames(projects)
        let events = todayEvents
        // Once per render, not once per use.
        let items = self.items
        List(selection: taskSelection) {
            Section {
                // The next prayer and its countdown; opens «أوقات الصلاة».
                NextPrayerLine { sheet = .prayers }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                // «ملخص اليوم» from the assistant; hidden offline.
                DaySummaryRow()
                if items.isEmpty { EmptyLine(text: "لا مهام اليوم. يومك لك.") }
                ForEach(items) { task in
                    TaskListItem(task: task, projectName: task.projectId.flatMap { names[$0] }, onCompleted: linger)
                }
            } header: {
                ScreenHeader(title: "اليوم", subtitle: formatter.dual(Date()))
            }
            // Apple Calendar's events today, read only, when «إظهار أحداث التقويم» is on.
            if !events.isEmpty {
                Section {
                    ForEach(events) { item in
                        EventRow(item: item) { sheet = .event(item) }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("أحداث اليوم")
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.ink)
                        .textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .zimamList()
        .overlay(alignment: .bottomTrailing) { AddTaskButton { sheet = .add } }
        .sheet(item: $sheet) { route in
            switch route {
            case .add: AddTaskView(due: .today)
            case .prayers: PrayerTimesSheet()
            case .event(let item): CalendarEventSheet(item: item)
            }
        }
        // «أوقات الصلاة» from the prayer widget (zimam://prayer).
        .onChange(of: PlaceOpener.shared.pending, initial: true) { _, link in openPending(link) }
        .toolbar { ToolbarItem { AccountMenu() } }
    }

    private func openPending(_ link: AppLink?) {
        guard link == .prayer else { return }
        PlaceOpener.shared.pending = nil
        sheet = .prayers
    }

    private func linger(_ id: UUID) {
        lingering.hold(id, animation: .zimam(reduceMotion: reduceMotion))
    }
}
