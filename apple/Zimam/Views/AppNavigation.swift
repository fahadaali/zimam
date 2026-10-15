import SwiftUI

/// What the sidebar shows on the iPad and the Mac. Saved per window (`@SceneStorage`), so it
/// survives rotation, resizing between the iPhone and iPad layouts, and relaunch.
enum SidebarItem: Hashable {
    case today
    case upcoming
    case inbox
    case calendar
    case search
    case project(UUID)
    case section(project: UUID, section: UUID)

    /// The iPhone tab that shows the same place.
    var tab: MainTab {
        switch self {
        case .today: .today
        case .upcoming: .upcoming
        case .search: .search
        case .calendar: .calendar
        case .inbox, .project, .section: .projects
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
        case .search: "search"
        case .project(let id): "project:\(id.uuidString)"
        case .section(let project, let section): "section:\(project.uuidString):\(section.uuidString)"
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

extension EnvironmentValues {
    /// The task shown in the details column on the iPad and the Mac. Lists bind it with
    /// `List(selection:)`, so a row's `NavigationLink(value: TaskRoute)` selects the task
    /// instead of pushing it. Nil on the iPhone, where rows push the details as before.
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
}

// MARK: Menu commands

/// What the window's menu commands act on (⌘N, ⌘F, ⌘↩), published by `MainView`.
struct ZimamSceneActions {
    var newTask: () -> Void
    var search: () -> Void
    /// Completes or reopens the selected task; nil when no task is selected.
    var toggleSelectedDone: (() -> Void)?
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

/// The Mac menu: «مهمة جديدة» in the File menu in place of «New Window», and a «المهام» menu.
struct ZimamCommands: Commands {
    @FocusedValue(\.zimamActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("مهمة جديدة") { actions?.newTask() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
        }
        CommandMenu("المهام") {
            Button("بحث") { actions?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("إنجاز المهمة المحددة") { actions?.toggleSelectedDone?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.toggleSelectedDone == nil)
        }
    }
}
