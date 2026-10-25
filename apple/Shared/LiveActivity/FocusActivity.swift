#if os(iOS)
import ActivityKit
import Foundation
import SwiftData

/// «المهمة الجارية»: a Live Activity for the task the user is focusing on, with a timer
/// on the Lock Screen and in the Dynamic Island. Started from the task's details in the app;
/// its views live in the widget extension (ZimamWidgets/FocusLiveActivity.swift).
/// Not tied to the main actor: ActivityKit reads the attributes from its own threads.
nonisolated struct FocusActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        /// When the focus started; the timer counts up from here.
        var startedAt: Date
        /// The task's title and project once renamed or moved while it runs. Attributes cannot
        /// change after the start, the state can; nil until then, so the attributes show.
        var title: String? = nil
        var projectName: String? = nil
    }

    var taskId: UUID
    var title: String
    var projectName: String?
}

/// Starts and ends the focus activity. One task at a time: starting another ends the first.
@MainActor
enum FocusActivity {
    /// The system keeps a Live Activity up to eight hours; the timer stops there too.
    static let maxDuration: TimeInterval = 8 * 3600

    /// Off when the user turned Live Activities off for Zimam in Settings.
    static var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    static func isRunning(_ taskId: UUID) -> Bool {
        running.contains { $0.attributes.taskId == taskId }
    }

    static var isAnyRunning: Bool {
        !running.isEmpty
    }

    /// Called after a task's focus ended, wherever from: the app turns Do Not Disturb off with it
    /// (`FocusDoNotDisturb`). Set at launch; nil in the widget extension.
    static var onEnd: (@MainActor () -> Void)?

    @discardableResult
    static func start(taskId: UUID, title: String, projectName: String?) async -> Bool {
        await endAll()
        let now = Date()
        let attributes = FocusActivityAttributes(taskId: taskId, title: title, projectName: projectName)
        let content = ActivityContent(state: FocusActivityAttributes.ContentState(startedAt: now),
                                      staleDate: now.addingTimeInterval(maxDuration))
        do {
            _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            return true
        } catch {
            return false
        }
    }

    /// Ends the focus on this task, and removes it from the Lock Screen right away.
    static func end(taskId: UUID) async {
        await endActivities(for: taskId)
        onEnd?()
    }

    /// Ends the focus when its task was completed or deleted elsewhere: in the Today list, from a
    /// notification, by Siri, or on another device; and shows its new title or project when it
    /// was renamed or moved. The app calls it after every change.
    static func endFinished(in context: ModelContext) {
        for activity in running {
            let id = activity.attributes.taskId
            var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let task = try? context.fetch(descriptor).first, !task.isDone, !task.pendingDelete else {
                Task { await FocusActivity.end(taskId: id) }
                continue
            }
            var projectName: String?
            if let projectId = task.projectId {
                var projects = FetchDescriptor<ProjectItem>(predicate: #Predicate { $0.id == projectId })
                projects.fetchLimit = 1
                projectName = (try? context.fetch(projects).first)?.name
            }
            let state = activity.content.state
            let shownTitle = state.title ?? activity.attributes.title
            let shownProject = state.title == nil ? activity.attributes.projectName : state.projectName
            if task.title != shownTitle || projectName != shownProject {
                let title = task.title
                Task { await FocusActivity.retitle(taskId: id, title: title, projectName: projectName) }
            }
        }
    }

    static func endAll() async {
        await endActivities(for: nil)
    }

    /// Ends one task's focus, or every one with nil. `Activity` is not Sendable, so the
    /// activities are looked up off the main actor, where ActivityKit ends them, rather than
    /// handed over from it.
    @concurrent nonisolated private static func endActivities(for taskId: UUID?) async {
        for activity in Activity<FocusActivityAttributes>.activities
        where activity.activityState == .active || activity.activityState == .stale {
            guard taskId == nil || activity.attributes.taskId == taskId else { continue }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Puts the task's current title and project in the activity's state, keeping its start and
    /// stale date, so the timer is unaffected. Off the main actor, as `endActivities`.
    @concurrent nonisolated private static func retitle(taskId: UUID, title: String, projectName: String?) async {
        for activity in Activity<FocusActivityAttributes>.activities
        where activity.attributes.taskId == taskId && (activity.activityState == .active || activity.activityState == .stale) {
            var state = activity.content.state
            state.title = title
            state.projectName = projectName
            await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
        }
    }

    private static var running: [Activity<FocusActivityAttributes>] {
        Activity<FocusActivityAttributes>.activities.filter { activity in
            activity.activityState == .active || activity.activityState == .stale
        }
    }
}
#endif
