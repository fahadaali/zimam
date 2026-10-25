import SwiftUI

/// What the sidebar shows on the iPad and the Mac. Saved per window (`@SceneStorage`), so it
/// survives rotation, resizing between the iPhone and iPad layouts, and relaunch.
enum SidebarItem: Hashable {
    case today
    case upcoming
    case inbox
    case calendar
    /// «المخطط الزمني» of every project and the inbox.
    case timeline
    /// «المصفوفة»: the open tasks in four quadrants.
    case matrix
    case search
    case project(UUID)
    case section(project: UUID, section: UUID)

    /// The iPhone tab that shows the same place. The inbox, the timeline and the matrix live at the
    /// top of the projects tab (`OverviewRoute`), which keeps the iPhone's five tabs.
    var tab: MainTab {
        switch self {
        case .today: .today
        case .upcoming: .upcoming
        case .search: .search
        case .calendar: .calendar
        case .inbox, .project, .section, .timeline, .matrix: .projects
        }
    }

    /// The overview this item opens on the iPhone's projects tab, if it is one.
    var overview: OverviewRoute? {
        switch self {
        case .inbox: .inbox
        case .timeline: .timeline
        case .matrix: .matrix
        default: nil
        }
    }

    /// The project this item belongs to, if any.
    var projectId: UUID? {
        switch self {
        case .project(let id): id
        case .section(let project, _): project
        default: nil
        }
    }
}

extension SidebarItem: RawRepresentable {
    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":").map(String.init)
        switch parts.first {
        case "today": self = .today
        case "upcoming": self = .upcoming
        case "inbox": self = .inbox
        case "calendar": self = .calendar
        case "timeline": self = .timeline
        case "matrix": self = .matrix
        case "search": self = .search
        case "project":
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            self = .project(id)
        case "section":
            guard parts.count == 3, let project = UUID(uuidString: parts[1]), let section = UUID(uuidString: parts[2]) else {
                return nil
            }
            self = .section(project: project, section: section)
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .today: "today"
        case .upcoming: "upcoming"
        case .inbox: "inbox"
        case .calendar: "calendar"
        case .timeline: "timeline"
        case .matrix: "matrix"
        case .search: "search"
        case .project(let id): "project:\(id.uuidString)"
        case .section(let project, let section): "section:\(project.uuidString):\(section.uuidString)"
        }
    }
}

/// «صندوق المهام», «المخطط الزمني» and «المصفوفة» pushed on the iPhone's projects tab; the
/// sidebar lists them on the iPad and the Mac.
enum OverviewRoute: Hashable {
    case inbox, timeline, matrix

    var sidebarItem: SidebarItem {
        switch self {
        case .inbox: .inbox
        case .timeline: .timeline
        case .matrix: .matrix
        }
    }

    var title: String {
        switch self {
        case .inbox: "صندوق المهام"
        case .timeline: "المخطط الزمني"
        case .matrix: "المصفوفة"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .timeline: "calendar.day.timeline.leading"
        case .matrix: "square.grid.2x2"
        }
    }
}

/// The iPhone tabs.
enum MainTab: String, Hashable {
    case today, upcoming, calendar, projects, search

    /// The sidebar item for this tab when the window widens; nil keeps the current one.
    var sidebarItem: SidebarItem? {
        switch self {
        case .today: .today
        case .upcoming: .upcoming
        case .calendar: .calendar
        case .search: .search
        case .projects: nil
        }
    }
}

// MARK: Task selection

private struct TaskSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<TaskRoute?>? = nil
}

private struct ProjectOpenedKey: EnvironmentKey {
    static let defaultValue: ((UUID) -> Void)? = nil
}

private struct ProjectClosedKey: EnvironmentKey {
    static let defaultValue: ((UUID) -> Void)? = nil
}

private struct OverviewOpenedKey: EnvironmentKey {
    static let defaultValue: ((OverviewRoute) -> Void)? = nil
}

private struct TaskCompleteInToolbarKey: EnvironmentKey {
    static let defaultValue = true
}

private struct CalendarDayChangedKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// The task shown in the details column on the iPad and the Mac. Lists bind it with
    /// `List(selection:)`, so a row's `NavigationLink(value: TaskRoute)` selects the task
    /// instead of pushing it; task links outside a list (`TaskOpenLink`) set it themselves.
    /// Nil on the iPhone, where rows push the details as before.
    var taskSelection: Binding<TaskRoute?>? {
        get { self[TaskSelectionKey.self] }
        set { self[TaskSelectionKey.self] = newValue }
    }

    /// Told when a project screen opens on the iPhone, so the sidebar shows the same
    /// project if the window widens.
    var projectOpened: ((UUID) -> Void)? {
        get { self[ProjectOpenedKey.self] }
        set { self[ProjectOpenedKey.self] = newValue }
    }

    /// Told when a project is deleted, archived or left from its own screen, or is gone after a pull:
    /// on the iPad and the Mac the sidebar leaves it for the inbox, as its screen is a column that
    /// cannot be dismissed.
    var projectClosed: ((UUID) -> Void)? {
        get { self[ProjectClosedKey.self] }
        set { self[ProjectClosedKey.self] = newValue }
    }

    /// Told when the inbox, the timeline or the matrix opens on the iPhone, for the same reason.
    var overviewOpened: ((OverviewRoute) -> Void)? {
        get { self[OverviewOpenedKey.self] }
        set { self[OverviewOpenedKey.self] = newValue }
    }

    /// Told when the calendar's selected day changes, so the menu's «مهمة جديدة» (⌘N) adds on
    /// that day, as the calendar's own add button does.
    var calendarDayChanged: ((String) -> Void)? {
        get { self[CalendarDayChangedKey.self] }
        set { self[CalendarDayChangedKey.self] = newValue }
    }

    /// Whether a task's details show «إنجاز» in their own toolbar. Off in the inspector on the
    /// iPad and the Mac, whose toolbar has the button that the menu's ⌘↩ also presses.
    var taskCompleteInToolbar: Bool {
        get { self[TaskCompleteInToolbarKey.self] }
        set { self[TaskCompleteInToolbarKey.self] = newValue }
    }
}

// MARK: Menu commands

/// What the window's menu commands act on (⌘N, ⌘F, ⌘↩, ⌘R), published by `MainView`: the menu
/// bar on the Mac, and on the iPad the keyboard's shortcuts (held ⌘ lists them). They change the
/// window's state, so they run on the main actor, as the menu calls them.
struct ZimamSceneActions {
    var newTask: @MainActor () -> Void
    var search: @MainActor () -> Void
    /// Completes or reopens the selected task; nil when no task is selected.
    var toggleSelectedDone: (@MainActor () -> Void)? = nil
    /// «مزامنة الآن», as in the account menu.
    var syncNow: (@MainActor () -> Void)? = nil
}

private struct ZimamActionsKey: FocusedValueKey {
    typealias Value = ZimamSceneActions
}

extension FocusedValues {
    var zimamActions: ZimamSceneActions? {
        get { self[ZimamActionsKey.self] }
        set { self[ZimamActionsKey.self] = newValue }
    }
}

/// The menu, the one source of the shortcuts on the Mac and the iPad: «مهمة جديدة» in the File
/// menu, in place of «New Window», and a «المهام» menu.
struct ZimamCommands: Commands {
    @FocusedValue(\.zimamActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) { newTask }
        CommandMenu("المهام") {
            Button("بحث") { actions?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("إنجاز المهمة المحددة") { actions?.toggleSelectedDone?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.toggleSelectedDone == nil)
            Button("مزامنة الآن") { actions?.syncNow?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.syncNow == nil)
        }
    }

    private var newTask: some View {
        Button("مهمة جديدة") { actions?.newTask() }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions == nil)
    }
}
