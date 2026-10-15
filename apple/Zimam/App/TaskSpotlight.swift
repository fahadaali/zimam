import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import ZimamKit

/// Keeps the open tasks in Spotlight as `TaskEntity` (`IndexedEntity`, iOS 18 and macOS 15), so
/// they appear in system search and Siri and Apple Intelligence can find them by their words.
/// Runs a few seconds after each sync or local edit (`SyncEngine.onDataChanged`): indexes only
/// tasks that changed since the last run, and removes completed, deleted and signed-out ones.
/// The index stays on the device.
@MainActor
final class TaskSpotlight {
    static let shared = TaskSpotlight()

    /// What was indexed last: task id to a fingerprint of what Spotlight shows for it.
    private static let indexedKey = "spotlight.indexedTasks"
    /// Plenty for open tasks; the nearest due dates first if there are more.
    private static let limit = 2000

    private var pending: Task<Void, Never>?

    private init() {}

    /// Updates the index soon, folding a burst of edits into one pass.
    func scheduleUpdate() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.update()
        }
    }

    func update() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let context = ZimamStore.shared.mainContext
        let all = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let projects = (try? context.fetch(FetchDescriptor<ProjectItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let open = all
            .filter { !$0.isDone }
            .sorted { ($0.dueDate ?? "9999-12-31", $0.createdAt) < ($1.dueDate ?? "9999-12-31", $1.createdAt) }
            .prefix(Self.limit)

        // Relative words («اليوم», «غداً») and the calendar change what is shown, so they are
        // part of the fingerprint: each task is indexed again once a day at most.
        let today = DualDateFormatter().dayString(from: Date())
        let calendar = SharedSettings.user()?.settings.calendar.rawValue ?? ""
        let previous = UserDefaults.standard.dictionary(forKey: Self.indexedKey) as? [String: String] ?? [:]
        let formatter = TaskEntity.userFormatter()
        var current: [String: String] = [:]
        var changed: [TaskEntity] = []
        for task in open {
            let projectName = task.projectId.flatMap { names[$0] }
            let key = task.id.uuidString
            let fingerprint = "\(today)|\(calendar)|\(task.updatedAt)|\(projectName ?? "")"
            current[key] = fingerprint
            if previous[key] != fingerprint {
                changed.append(TaskEntity(task, projectName: projectName, formatter: formatter))
            }
        }
        let removed = previous.keys.filter { current[$0] == nil }.compactMap(UUID.init(uuidString:))

        let index = CSSearchableIndex.default()
        do {
            if !removed.isEmpty {
                try await index.deleteAppEntities(identifiedBy: removed, ofType: TaskEntity.self)
            }
            if !changed.isEmpty {
                try await index.indexAppEntities(changed)
            }
            UserDefaults.standard.set(current, forKey: Self.indexedKey)
        } catch {
            // Kept as it was; the next update tries the same changes again.
        }
    }
}
