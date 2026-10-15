import AppIntents
import Foundation
import Observation
import SwiftData
import ZimamKit

// A task said as one sentence to Siri, and opening a task from Siri, Shortcuts or Spotlight.
// Like the other intents these run in the app's process and write through `Store`.

/// «ذكّرني في زمام» then «أراجع العقد بعد العصر بكرة»: the assistant reads the sentence on the
/// server (title, day, time or prayer, priority, project) and the task is added at once. Signed
/// out, offline, without the assistant, or when it is slow, the sentence becomes the title.
struct AddTaskFromSentenceIntent: AppIntent {
    static var title: LocalizedStringResource = "إضافة مهمة بجملة"
    static var description = IntentDescription(
        "قل المهمة كما تقولها لشخص، مثل «ذكرني أراجع العقد بعد العصر بكرة»، فيقرأ المساعد موعدها ويضيفها. دون اتصال أو دون المساعد تُضاف الجملة عنواناً كما هي.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "الجملة", requestValueDialog: IntentDialog("ما المهمة؟"))
    var sentence: String

    static var parameterSummary: some ParameterSummary {
        Summary("أضف «\(\.$sentence)» إلى زمام")
    }

    init() {}

    init(sentence: String) {
        self.sentence = sentence
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return .result(dialog: "لم تُضف المهمة لأن الجملة فارغة.")
        }
        let formatter = DualDateFormatter(primary: SharedSettings.user()?.settings.calendar ?? .hijri, locale: ZimamLocale.current)
        let reading: SpokenTask
        if let api = SessionStore.storedSessionAPI() {
            if NetworkMonitor.shared.isOnline {
                reading = await api.readSpokenTask(text, timeZone: formatter.timeZone)
            } else {
                reading = SpokenTask(text: text, problem: .offline)
            }
        } else {
            reading = SpokenTask(text: text, problem: .signedOut)
        }

        let context = ZimamStore.shared.mainContext
        let record = reading.record(today: formatter.dayString(from: Date()))
        // A project not on this device yet is left out, as in the add screen.
        var projectId: UUID?
        if let id = record.projectId {
            var descriptor = FetchDescriptor<ProjectItem>(predicate: #Predicate { $0.id == id && !$0.pendingDelete })
            descriptor.fetchLimit = 1
            if (try? context.fetch(descriptor).first) != nil { projectId = id }
        }
        let task = Store(context: context, sync: LiveSync.engine).addTask(
            title: record.title,
            projectId: projectId,
            dueDate: record.dueDate,
            duePrayer: record.duePrayer,
            duePrayerOffset: record.duePrayerOffset,
            priority: record.priority,
            notes: record.notes,
            dueTime: record.dueTime,
            tags: record.tags
        )
        let message = Self.confirmation(for: task, reading: reading, formatter: formatter)
        return .result(dialog: "\(message)")
    }

    /// «أُضيفت «مراجعة العقد»، غداً، بعد العصر.», with a note when the sentence was kept as said.
    @MainActor
    static func confirmation(for task: TaskItem, reading: SpokenTask, formatter: DualDateFormatter) -> String {
        var when: [String] = []
        if let day = task.dueDate.flatMap(formatter.date(fromDay:)) {
            when.append(formatter.label(for: day))
            if let time = task.dueTime.flatMap({ clockTime($0, on: day, formatter: formatter) }) {
                when.append(time)
            }
        }
        if let prayer = task.duePrayer {
            when.append(PrayerPhrase.text(prayer, offsetMinutes: task.duePrayerOffset, locale: formatter.locale))
        }
        let suffix = when.isEmpty ? "" : "، " + when.joined(separator: "، ")
        var text = "أُضيفت «\(task.title)»\(suffix)."
        switch reading.problem {
        case nil:
            break
        case .offline?:
            text += " لا اتصال الآن، فأُضيفت الجملة كما قلتها."
        case .signedOut?:
            text += " سجّل الدخول في زمام ليقرأ المساعد مواعيد ما تقوله."
        default:
            text += " لم يقرأها المساعد هذه المرة، فأُضيفت الجملة كما قلتها."
        }
        return text
    }
}

/// Opens a task's details in the app: from Shortcuts, from Siri («افتح مهمة في زمام»), and from
/// a Spotlight result (tasks are indexed as `TaskEntity`, see TaskSpotlight).
struct OpenTaskIntent: OpenIntent {
    static var title: LocalizedStringResource = "فتح مهمة"
    static var description = IntentDescription("يفتح تفاصيل مهمة في زمام.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "المهمة", requestValueDialog: IntentDialog("أي مهمة؟"))
    var target: TaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("افتح \(\.$target)")
    }

    init() {}

    init(target: TaskEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        TaskOpener.shared.pending = target.id
        return .result()
    }
}

/// The task an intent asked to open; `MainView` shows it and clears it. Kept until the main
/// screen exists, so a cold launch (or signing in first) still opens the task.
@MainActor
@Observable
final class TaskOpener {
    static let shared = TaskOpener()

    var pending: UUID?

    private init() {}
}

extension SessionStore {
    /// An API client with this device's session, for intents that run without the app's views
    /// (Siri in the background). Nil when signed out. Built as `SessionStore` builds its own.
    nonisolated static func storedSessionAPI() -> APIClient? {
        guard Keychain.read(tokenAccount) != nil else { return nil }
        let configured = Bundle.main.object(forInfoDictionaryKey: "ZimamAPIURL") as? String
        let baseURL = configured.flatMap(URL.init(string:)) ?? URL(string: "https://zimam.fahad2ao.workers.dev")!
        return APIClient(baseURL: baseURL) { Keychain.read(SessionStore.tokenAccount) }
    }
}
