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
    }

    /// Ends the focus when its task was completed or deleted elsewhere: in the Today list, from a
    /// notification, by Siri, or on another device. The app calls it after every change.
    static func endFinished(in context: ModelContext) {
        let ids = Set(running.map(\.attributes.taskId))
        guard !ids.isEmpty else { return }
        for id in ids {
            var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let task = try? context.fetch(descriptor).first
            if task == nil || task?.isDone == true || task?.pendingDelete == true {
                Task { await FocusActivity.end(taskId: id) }
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

    private static var running: [Activity<FocusActivityAttributes>] {
        Activity<FocusActivityAttributes>.activities.filter { activity in
            activity.activityState == .active || activity.activityState == .stale
        }
    }
}
#endif
