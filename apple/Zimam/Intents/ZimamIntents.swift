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

/// Before or after a prayer, for the «add task» intent.
enum PrayerRelationOption: String, AppEnum, CaseIterable {
    case before, after

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "قبل الصلاة أو بعدها"
    static let caseDisplayRepresentations: [PrayerRelationOption: DisplayRepresentation] = [
        .before: "قبل",
        .after: "بعد",
    ]
}

/// A prayer and before or after it, said in one Siri phrase: «ذكرني في زمام قبل المغرب».
/// One parameter per phrase is all App Shortcuts allow, so the two are one value. «قبل» alone is
/// a quarter of an hour before the adhan (`SpokenTime.defaultBeforeMinutes`), «بعد» at the adhan.
enum PrayerMoment: String, AppEnum, CaseIterable {
    case beforeFajr, afterFajr, beforeDhuhr, afterDhuhr, beforeAsr, afterAsr
    case beforeMaghrib, afterMaghrib, beforeIsha, afterIsha

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "وقت الصلاة"
    static let caseDisplayRepresentations: [PrayerMoment: DisplayRepresentation] = [
        .beforeFajr: "قبل الفجر",
        .afterFajr: "بعد الفجر",
        .beforeDhuhr: "قبل الظهر",
        .afterDhuhr: "بعد الظهر",
        .beforeAsr: "قبل العصر",
        .afterAsr: "بعد العصر",
        .beforeMaghrib: "قبل المغرب",
        .afterMaghrib: "بعد المغرب",
        .beforeIsha: "قبل العشاء",
        .afterIsha: "بعد العشاء",
    ]

    var prayer: Prayer {
        switch self {
        case .beforeFajr, .afterFajr: .fajr
        case .beforeDhuhr, .afterDhuhr: .dhuhr
        case .beforeAsr, .afterAsr: .asr
        case .beforeMaghrib, .afterMaghrib: .maghrib
        case .beforeIsha, .afterIsha: .isha
        }
    }

    var offset: Int {
        switch self {
        case .beforeFajr, .beforeDhuhr, .beforeAsr, .beforeMaghrib, .beforeIsha: -SpokenTime.defaultBeforeMinutes
        default: 0
        }
    }
}

/// «ذكرني في زمام بعد العصر» then «أتصل بأبي»: the task at that prayer, today or, once it has
/// passed, tomorrow. A day in the sentence («بكرة») is kept, and a prayer in it wins over the phrase's.
struct AddPrayerTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "إضافة مهمة بوقت صلاة"
    static let description = IntentDescription(
        "قل «ذكرني في زمام قبل المغرب» أو «بعد العصر» ثم المهمة، فتُضاف مرتبطة بالصلاة. «قبل» تذكّرك قبل الأذان بربع ساعة.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "وقت الصلاة", requestValueDialog: IntentDialog("قبل أي صلاة أو بعدها؟"))
    var moment: PrayerMoment

    @Parameter(title: "المهمة", requestValueDialog: IntentDialog("ما المهمة؟"))
    var sentence: String

    static var parameterSummary: some ParameterSummary {
        Summary("أضف «\(\.$sentence)» \(\.$moment)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await AddTaskFromSentenceIntent.add(sentence: sentence, moment: moment)
        return .result(dialog: "\(message)")
    }
}

/// «أضف مهمة في زمام»: a title, and optionally a day and a prayer with minutes before or after it.
/// A prayer without a day means today.
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

    @Parameter(title: "قبل الصلاة أو بعدها")
    var relation: PrayerRelationOption?

    /// Minutes before or after the prayer (`relation`). Negative still means before, as shortcuts
    /// made before `relation` existed send it.
    @Parameter(title: "الدقائق")
    var offsetMinutes: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("أضف «\(\.$taskTitle)» إلى زمام") {
            \.$date
            \.$prayer
            \.$relation
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
        let offset: Int? = duePrayer == nil ? nil : {
            switch relation {
            case .before?: return -abs(offsetMinutes ?? SpokenTime.defaultBeforeMinutes)
            case .after?: return abs(offsetMinutes ?? 0)
            case nil: return offsetMinutes ?? 0
            }
        }()
        let store = Store(context: ZimamStore.shared.mainContext, sync: LiveSync.engine)
        let task = store.addTask(
            title: trimmed,
            dueDate: day.map { formatter.dayString(from: $0) },
            duePrayer: duePrayer,
            duePrayerOffset: offset
        )
        store.ensureAtTimeReminder(task)

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
        // The prayer in the phrase («بعد العصر»), then «ما المهمة؟».
        AppShortcut(
            intent: AddPrayerTaskIntent(),
            phrases: [
                "ذكرني في \(.applicationName) \(\.$moment)",
                "أضف مهمة في \(.applicationName) \(\.$moment)",
                "سجّل في \(.applicationName) مهمة \(\.$moment)",
            ],
            shortTitle: "مهمة بوقت صلاة",
            systemImageName: "moon.stars"
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
