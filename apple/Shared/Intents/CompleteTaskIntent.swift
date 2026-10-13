import AppIntents
import Foundation
import SwiftData
import ZimamKit

/// Completes a task: from Siri and Shortcuts (in the app's process) and from the widgets'
/// completion circle (in the widget extension's process). Either way it goes through `Store`,
/// so the task is marked dirty; the app's sync engine sends it right away when this process
/// has one, otherwise the app sends it the next time it opens.
struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "إنجاز مهمة"
    static var description = IntentDescription("ينجز مهمة في زمام.")

    @Parameter(title: "المهمة")
    var task: TaskEntity

    init() {}

    init(task: TaskEntity) {
        self.task = task
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ZimamStore.shared.mainContext
        let id = task.id
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let item = try? context.fetch(descriptor).first, !item.pendingDelete else {
            return .result(dialog: "لم أجد هذه المهمة في زمام.")
        }
        let title = item.title
        if item.isDone {
            return .result(dialog: "«\(title)» منجزة من قبل.")
        }
        Store(context: context, sync: LiveSync.engine).toggleDone(item)
        return .result(dialog: "أُنجزت «\(title)».")
    }
}
