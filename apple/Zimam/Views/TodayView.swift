import SwiftData
import SwiftUI
import ZimamKit

/// Open tasks due today or overdue, with the assistant's summary of the day on request.
/// A task completed here stays for a second so it can be undone.
struct TodayView: View {
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.taskSelection) private var taskSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]
    @State private var showingAdd = false
    @State private var showingPrayers = false
    @State private var lingering = Lingering()
    /// The Apple Calendar event whose details are open.
    @State private var openEvent: ShownEvent?

    private var items: [TaskItem] {
        let today = formatter.dayString(from: Date())
        return tasks
            .filter { task in
                guard task.parentId == nil, let due = task.dueDate, due <= today else { return false }
                return !task.isDone || lingering.contains(task.id)
            }
            .sorted { ($0.dueDate ?? "", $0.dueTime ?? "") < ($1.dueDate ?? "", $1.dueTime ?? "") }
    }

    var body: some View {
        let names = projectNames(projects)
        let events = todayEvents
        // Once per render, not once per use.
        let items = self.items
        List(selection: taskSelection) {
            Section {
                // The next prayer and its countdown; opens «أوقات الصلاة».
                NextPrayerLine { showingPrayers = true }
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
                        EventRow(item: item) { openEvent = item }
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
        .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
        .sheet(isPresented: $showingAdd) { AddTaskView(due: .today) }
        .sheet(isPresented: $showingPrayers) { PrayerTimesSheet() }
        .sheet(item: $openEvent) { item in CalendarEventSheet(item: item) }
        .toolbar { ToolbarItem { AccountMenu() } }
    }

    private var todayEvents: [ShownEvent] {
        let today = formatter.dayString(from: Date())
        return CalendarEvents.shared.events(from: today, to: today, timeZone: formatter.timeZone)
    }

    private func linger(_ id: UUID) {
        lingering.hold(id, animation: .zimam(reduceMotion: reduceMotion))
    }
}
