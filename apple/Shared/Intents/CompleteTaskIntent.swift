import AppIntents
import Foundation
import SwiftData
import UserNotifications
import ZimamKit

/// Completes a task: from Siri and Shortcuts, and from the widgets' completion circle. On iPhone
/// and iPad it runs in the app's process, launched in the background if needed (a
/// `LiveActivityIntent`, below), so the notifications are replanned (the next occurrence's
/// reminders added), the app's sync engine sends the edit (waited for a few seconds at most,
/// `LiveSync.intentWait`) and «المهمة الجارية» ends, before it returns.
/// The Mac's widgets run it in the widget extension: the task is marked dirty and the app sends it
/// the next time it syncs, and its reminders on this device are taken back at once.
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "إنجاز مهمة"
    static let description = IntentDescription("ينجز مهمة في زمام.")
    /// Done in place, from Siri or a widget, without opening the app.
    static let openAppWhenRun: Bool = false

    @Parameter(title: "المهمة", requestValueDialog: IntentDialog("أي مهمة؟"))
    var task: TaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("أنجز \(\.$task)")
    }

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
        if let flush = LiveSync.flush {
            await flush(LiveSync.intentWait)
        } else {
            await Self.removeNotifications(of: id)
        }
        return .result(dialog: "أُنجزت «\(title)».")
    }

    /// Without the app's process (the Mac's widgets), the task's reminders still waiting on this
    /// device are taken back, and delivered ones cleared, so a done task does not alert. The app
    /// replans the rest, the next occurrence's included, when it next runs.
    private static func removeNotifications(of taskId: UUID) async {
        let center = UNUserNotificationCenter.current()
        func isTask(_ content: UNNotificationContent) -> Bool {
            // Pushed reminders carry the server's lowercase id, so compare as UUIDs.
            (content.userInfo["taskId"] as? String).flatMap(UUID.init(uuidString:)) == taskId
        }
        let pending = await center.pendingNotificationRequests().filter { isTask($0.content) }.map(\.identifier)
        if !pending.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pending) }
        let delivered = await center.deliveredNotifications().filter { isTask($0.request.content) }.map(\.request.identifier)
        if !delivered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: delivered) }
    }
}

#if os(iOS)
/// A widget's button runs a `LiveActivityIntent` in the app's process, where the sync engine is.
extension CompleteTaskIntent: LiveActivityIntent {}
#endif
