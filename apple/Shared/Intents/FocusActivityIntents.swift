#if os(iOS)
import AppIntents
import Foundation
import SwiftData

/// «إنجاز» on the focus Live Activity: completes the task through `Store` (with the next
/// occurrence of a recurring task) and ends the activity. As a `LiveActivityIntent` it runs in
/// the app's process, launched in the background if needed, so the edit syncs through the
/// app's engine when it has one.
struct CompleteFocusTaskIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "إنجاز المهمة الجارية"
    static var description = IntentDescription("ينجز المهمة الجارية في زمام وينهي التركيز عليها.")
    /// Only the Live Activity's button runs it; Siri and Shortcuts have CompleteTaskIntent.
    static var isDiscoverable = false

    @Parameter(title: "المهمة")
    var taskId: String

    init() {}

    init(taskId: UUID) {
        self.taskId = taskId.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskId) else { return .result() }
        let context = ZimamStore.shared.mainContext
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let item = try? context.fetch(descriptor).first, !item.pendingDelete, !item.isDone {
            Store(context: context, sync: LiveSync.engine).toggleDone(item)
        }
        await FocusActivity.end(taskId: id)
        return .result()
    }
}

/// «إنهاء» on the focus Live Activity: ends the focus without completing the task.
struct EndFocusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "إنهاء التركيز"
    static var description = IntentDescription("ينهي التركيز على المهمة الجارية دون إنجازها.")
    static var isDiscoverable = false

    @Parameter(title: "المهمة")
    var taskId: String

    init() {}

    init(taskId: UUID) {
        self.taskId = taskId.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: taskId) {
            await FocusActivity.end(taskId: id)
        }
        return .result()
    }
}
#endif
