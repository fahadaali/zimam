import AppIntents
import Foundation
import SwiftData
import ZimamKit

// Siri and Shortcuts. These run in the app's process (in the background when the app is
// closed) and write through `Store`, like every other edit, so the tasks are marked for
// sync and the widgets reload.

/// The five prayers, for the «add task» intent.
enum PrayerOption: String, AppEnum, CaseIterable {
    case fajr, dhuhr, asr, maghrib, isha

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "الصلاة"
    static let caseDisplayRepresentations: [PrayerOption: DisplayRepresentation] = [
        .fajr: "الفجر",
        .dhuhr: "الظهر",
        .asr: "العصر",
        .maghrib: "المغرب",
        .isha: "العشاء",
    ]

    var prayer: Prayer {
        Prayer(rawValue: rawValue) ?? .fajr
    }
}

/// «أضف مهمة في زمام»: a title, and optionally a day and a prayer with minutes after it
/// (negative for before). A prayer without a day means today.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "إضافة مهمة"
    static let description = IntentDescription("يضيف مهمة إلى زمام، بتاريخ أو بوقت صلاة إن شئت.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "العنوان")
    var taskTitle: String

    @Parameter(title: "التاريخ")
    var date: Date?

    @Parameter(title: "الصلاة")
    var prayer: PrayerOption?

    @Parameter(title: "الدقائق بعد الصلاة")
    var offsetMinutes: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("أضف «\(\.$taskTitle)» إلى زمام") {
            \.$date
            \.$prayer
            \.$offsetMinutes
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .result(dialog: "لم تُضف المهمة لأن عنوانها فارغ.")
        }
        let formatter = DualDateFormatter(primary: SharedSettings.user()?.settings.calendar ?? .hijri, locale: ZimamLocale.current)
        let day: Date? = date ?? (prayer == nil ? nil : Date())
        let duePrayer = prayer?.prayer
        let offset = duePrayer == nil ? nil : (offsetMinutes ?? 0)
        let task = Store(context: ZimamStore.shared.mainContext, sync: LiveSync.engine).addTask(
            title: trimmed,
            dueDate: day.map { formatter.dayString(from: $0) },
            duePrayer: duePrayer,
            duePrayerOffset: offset
        )

        var when: [String] = []
        if let day { when.append(formatter.label(for: day)) }
        if let duePrayer { when.append(PrayerPhrase.text(duePrayer, offsetMinutes: offset, locale: formatter.locale)) }
        let suffix = when.isEmpty ? "" : "، " + when.joined(separator: "، ")
        return .result(dialog: "أُضيفت «\(task.title)»\(suffix).")
    }
}

/// «ما مهام اليوم في زمام»: reads today's open tasks, overdue ones included.
struct TodayTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "مهام اليوم"
    static let description = IntentDescription("يقرأ مهام اليوم المفتوحة في زمام.")
    static let openAppWhenRun: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tasks = TodayTasks.fetch(in: ZimamStore.shared.mainContext, today: TodayTasks.todayString())
        if tasks.isEmpty {
            return .result(dialog: "لا مهام اليوم. يومك لك.")
        }
        let shown = tasks.prefix(10).map(\.title).joined(separator: "، ")
        let more = tasks.count > 10 ? "، وغيرها" : ""
        let count = ArabicCount.tasks(tasks.count, locale: ZimamLocale.current)
        return .result(dialog: "لديك اليوم \(count): \(shown)\(more).")
    }
}

/// The phrases Siri knows without setup. Each one names the app.
struct ZimamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "أضف مهمة في \(.applicationName)",
                "مهمة جديدة في \(.applicationName)",
                "سجّل مهمة في \(.applicationName)",
            ],
            shortTitle: "إضافة مهمة",
            systemImageName: "plus.circle"
        )
        // A free sentence cannot be part of the phrase, so Siri asks «ما المهمة؟» after it.
        AppShortcut(
            intent: AddTaskFromSentenceIntent(),
            phrases: [
                "ذكرني في \(.applicationName)",
                "ذكرني بشيء في \(.applicationName)",
                "أضف تذكيراً في \(.applicationName)",
                "سجّل تذكيراً في \(.applicationName)",
            ],
            shortTitle: "مهمة بجملة",
            systemImageName: "text.bubble"
        )
        // One parameter per phrase: the saved place, so Siri knows «البيت» and «العمل».
        AppShortcut(
            intent: AddPlaceReminderIntent(),
            phrases: [
                "ذكرني في \(.applicationName) إذا وصلت \(\.$place)",
                "ذكرني في \(.applicationName) عند الوصول إلى \(\.$place)",
                "ذكرني في \(.applicationName) لما أوصل \(\.$place)",
                "تذكير مكان في \(.applicationName)",
            ],
            shortTitle: "تذكير عند مكان",
            systemImageName: "mappin.and.ellipse"
        )
        AppShortcut(
            intent: TodayTasksIntent(),
            phrases: [
                "ما مهام اليوم في \(.applicationName)",
                "مهامي اليوم في \(.applicationName)",
                "اقرأ مهام اليوم من \(.applicationName)",
            ],
            shortTitle: "مهام اليوم",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: CompleteTaskIntent(),
            phrases: [
                "أنجز مهمة في \(.applicationName)",
                "علّم مهمة منجزة في \(.applicationName)",
            ],
            shortTitle: "إنجاز مهمة",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: OpenTaskIntent(),
            phrases: [
                "افتح مهمة في \(.applicationName)",
                "اعرض مهمة في \(.applicationName)",
            ],
            shortTitle: "فتح مهمة",
            systemImageName: "doc.text"
        )
    }
}
