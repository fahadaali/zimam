import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers
import ZimamKit

/// A task as Siri, Shortcuts, Spotlight and the widgets see it. The app indexes the open ones
/// in Spotlight (`IndexedEntity`, see Zimam/App/TaskSpotlight.swift), so they turn up in search
/// and Siri can find them by their words; a result opens with `OpenTaskIntent`.
struct TaskEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "مهمة"
    static var defaultQuery = TaskEntityQuery()

    let id: UUID
    let title: String
    /// When it is due and where it lives: «غداً، بعد العصر، العمل». The subtitle in Shortcuts.
    var detail: String?
    var notes: String?
    var tags: [String] = []

    init(id: UUID, title: String, detail: String? = nil, notes: String? = nil, tags: [String] = []) {
        self.id = id
        self.title = title
        self.detail = detail
        self.notes = notes
        self.tags = tags
    }

    /// `formatter` defaults to the user's calendar; pass one when making many.
    init(_ task: TaskItem, projectName: String? = nil, formatter: DualDateFormatter? = nil) {
        id = task.id
        title = task.title
        notes = task.notes.flatMap { $0.isEmpty ? nil : $0 }
        tags = task.tags
        let formatter = formatter ?? Self.userFormatter()
        var parts: [String] = []
        if let day = task.dueDate.flatMap(formatter.date(fromDay:)) {
            parts.append(formatter.label(for: day))
        }
        if let prayer = task.duePrayer {
            parts.append(PrayerPhrase.text(prayer, offsetMinutes: task.duePrayerOffset, locale: formatter.locale))
        }
        if let projectName { parts.append(projectName) }
        detail = parts.isEmpty ? nil : parts.joined(separator: "، ")
    }

    /// Dates the user's way: their primary calendar first.
    static func userFormatter() -> DualDateFormatter {
        DualDateFormatter(primary: SharedSettings.user()?.settings.calendar ?? .hijri, locale: ZimamLocale.current)
    }

    var displayRepresentation: DisplayRepresentation {
        if let detail {
            DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
        } else {
            DisplayRepresentation(title: "\(title)")
        }
    }

    /// What Spotlight shows and searches: the title, then the due date, project and notes.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.displayName = title
        let description = [detail, notes].compactMap { $0 }.joined(separator: "\n")
        attributes.contentDescription = description.isEmpty ? nil : description
        attributes.keywords = tags + ["مهمة", "زمام"]
        return attributes
    }
}

/// Finds tasks in the local store, by id (when an intent runs) or by words in the title
/// (when Siri or Shortcuts ask which task). Suggests today's tasks first.
struct TaskEntityQuery: EntityStringQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TaskEntity] {
        let wanted = Set(identifiers)
        let formatter = TaskEntity.userFormatter()
        return allTasks()
            .filter { wanted.contains($0.id) }
            .map { TaskEntity($0, formatter: formatter) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TaskEntity] {
        let matches = allTasks().filter { !$0.isDone && ArabicSearch.matches($0.title, query: string) }
        let formatter = TaskEntity.userFormatter()
        return Array(matches.prefix(20)).map { TaskEntity($0, formatter: formatter) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskEntity] {
        let context = ZimamStore.shared.mainContext
        let today = TodayTasks.fetch(in: context, today: TodayTasks.todayString())
        let tasks = today.isEmpty ? allTasks().filter { !$0.isDone && $0.parentId == nil } : today
        let formatter = TaskEntity.userFormatter()
        return Array(tasks.prefix(20)).map { TaskEntity($0, formatter: formatter) }
    }

    @MainActor
    private func allTasks() -> [TaskItem] {
        let context = ZimamStore.shared.mainContext
        return (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
    }
}
