#if os(iOS)
import AppIntents
import Foundation
import SwiftData
import ZimamKit

// «المهمة الجارية» for the user's own shortcuts: put after «تعيين التركيز», one shortcut turns
// Do Not Disturb on and starts the focus, from Siri, the Action button or Control Center.
// `LiveActivityIntent`s, so they run in the app's process, which may start a Live Activity from
// the background. They run no shortcut themselves (`FocusDoNotDisturb`): the user's shortcut
// already sets the Focus mode.

/// «بدء التركيز على مهمة».
struct StartFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "بدء التركيز على مهمة"
    static let description = IntentDescription(
        "يبدأ مؤقت المهمة في زمام على شاشة القفل وفي الجزيرة التفاعلية. ضع قبله «تعيين التركيز» ليعمل «عدم الإزعاج» معه.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "المهمة", requestValueDialog: IntentDialog("على أي مهمة؟"))
    var task: TaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("ابدأ التركيز على \(\.$task)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ZimamStore.shared.mainContext
        let id = task.id
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let item = try? context.fetch(descriptor).first, !item.pendingDelete else {
            return .result(dialog: "لم أجد هذه المهمة في زمام.")
        }
        if item.isDone {
            return .result(dialog: "«\(item.title)» منجزة من قبل.")
        }
        guard FocusActivity.isEnabled else {
            return .result(dialog: "الأنشطة الحية متوقفة لزمام. فعّلها من إعدادات النظام ← زمام.")
        }
        var projectName: String?
        if let projectId = item.projectId {
            var projects = FetchDescriptor<ProjectItem>(predicate: #Predicate { $0.id == projectId })
            projects.fetchLimit = 1
            projectName = (try? context.fetch(projects).first)?.name
        }
        guard await FocusActivity.start(taskId: item.id, title: item.title, projectName: projectName) else {
            return .result(dialog: "تعذّر بدء التركيز. حاول مرة أخرى.")
        }
        return .result(dialog: "بدأ التركيز على «\(item.title)».")
    }
}

/// «إنهاء التركيز الجاري»: ends the focus, whichever task it is on, without completing it.
struct StopFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "إنهاء التركيز الجاري"
    static let description = IntentDescription("ينهي التركيز الجاري في زمام دون إنجاز المهمة.")
    static let openAppWhenRun: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await FocusActivity.endAll()
        return .result()
    }
}
#endif
