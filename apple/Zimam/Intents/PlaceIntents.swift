import AppIntents
import Foundation
import SwiftData
import ZimamKit

// Saved places («أماكني») for Siri and Shortcuts: «ذكّرني في زمام إذا وصلت البيت», then the task.
// Places are added in the app, where the user picks them on the map; Siri only names them.

/// A saved place as Siri and Shortcuts see it. Siri learns the names from
/// `ZimamShortcuts.updateAppShortcutParameters()`, called when the data changes.
struct PlaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "مكان"
    static let defaultQuery = PlaceEntityQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Finds saved places by id, or by name as the search compares it («البيت» = «البَيت»).
struct PlaceEntityQuery: EntityStringQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PlaceEntity] {
        let wanted = Set(identifiers)
        return places().filter { wanted.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaceEntity] {
        places().filter { ArabicSearch.matches($0.name, query: string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaceEntity] {
        places()
    }

    @MainActor
    private func places() -> [PlaceEntity] {
        let descriptor = FetchDescriptor<PlaceItem>(predicate: #Predicate { !$0.pendingDelete },
                                                    sortBy: [SortDescriptor(\.name)])
        let items = (try? ZimamStore.shared.mainContext.fetch(descriptor)) ?? []
        return items.map { PlaceEntity(id: $0.id, name: $0.name) }
    }
}

/// Arriving or leaving.
enum PlaceTriggerOption: String, AppEnum, CaseIterable {
    case arrive, leave

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "التذكير"
    static let caseDisplayRepresentations: [PlaceTriggerOption: DisplayRepresentation] = [
        .arrive: "عند الوصول",
        .leave: "عند المغادرة",
    ]

    var trigger: ReminderRecord.Location.Trigger {
        self == .leave ? .leave : .arrive
    }
}

/// «ذكّرني في زمام إذا وصلت البيت» then «أشتري خبز»: adds the task with a reminder at the saved
/// place, and at a time too if given, whichever comes first.
struct AddPlaceReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "تذكير عند مكان"
    static let description = IntentDescription(
        "يضيف مهمة تذكّرك بها حين تصل إلى مكان من أماكنك أو تغادره، مثل البيت أو العمل. ومع وقت يصلك التذكير مرة عند أيهما أسبق. الأماكن تُضاف في التطبيق من «أماكني».")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "المكان", requestValueDialog: IntentDialog("أي مكان من أماكنك؟"))
    var place: PlaceEntity

    @Parameter(title: "المهمة", requestValueDialog: IntentDialog("بماذا أذكّرك؟"))
    var taskTitle: String

    @Parameter(title: "التذكير", default: .arrive)
    var trigger: PlaceTriggerOption

    @Parameter(title: "أو في وقت")
    var time: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("ذكّرني بـ«\(\.$taskTitle)» \(\.$trigger) \(\.$place)") {
            \.$time
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            return .result(dialog: "لم تُضف المهمة لأن عنوانها فارغ.")
        }
        let context = ZimamStore.shared.mainContext
        let id = place.id
        var descriptor = FetchDescriptor<PlaceItem>(predicate: #Predicate { $0.id == id && !$0.pendingDelete })
        descriptor.fetchLimit = 1
        guard let saved = try? context.fetch(descriptor).first else {
            return .result(dialog: "لم أجد «\(place.name)» في أماكنك. أضفه من الإعدادات في «أماكني».")
        }
        let formatter = DualDateFormatter(primary: SharedSettings.user()?.settings.calendar ?? .hijri, locale: ZimamLocale.current)
        let at = time.flatMap { $0 > Date() ? $0 : nil }
        let store = Store(context: context, sync: LiveSync.engine)
        let task = store.addTask(title: title)
        let copy = ReminderRecord.Location(place: saved.record, trigger: trigger.trigger)
        store.addLocationReminder(to: task.id, place: copy, at: at)

        let action = LocationReminderPlanner.placeText(copy)
        if let at {
            return .result(dialog: "أُضيفت «\(task.title)». سأذكّرك \(action) أو \(formatter.label(for: at)) \(formatter.time(at))، أيهما أسبق.")
        }
        return .result(dialog: "أُضيفت «\(task.title)». سأذكّرك \(action).")
    }
}
