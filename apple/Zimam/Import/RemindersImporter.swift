import EventKit
import Foundation
import Observation
import SwiftData
import ZimamKit

/// Imports Apple Reminders on the device: asks for full access to Reminders, lists the user's
/// reminder lists, and turns the chosen ones into projects and tasks through `Store`, so they
/// sync like any edit. What was imported is remembered per account (`RemindersImportRefs`),
/// so importing again adds only new reminders.
@MainActor
@Observable
final class RemindersImporter {
    enum Access: Equatable {
        case notDetermined, granted, denied, writeOnly, restricted
    }

    private(set) var access: Access
    private(set) var lists: [AppleRemindersImport.List] = []
    var selected: Set<String> = []
    private(set) var isWorking = false
    /// What the last import did, in Arabic.
    private(set) var resultMessage: String?
    private(set) var errorMessage: String?

    /// Made on first use: the view that owns this importer may be built often, the store is not cheap.
    @ObservationIgnored private var storage: EKEventStore?
    private var store: EKEventStore {
        if let storage { return storage }
        let made = EKEventStore()
        storage = made
        return made
    }

    init() {
        access = Self.currentAccess()
    }

    /// Reads the permission again (it may have changed in Settings) and the lists when allowed.
    func refresh() {
        access = Self.currentAccess()
        if access == .granted { loadLists() }
    }

    static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .writeOnly: return .writeOnly
        case .restricted: return .restricted
        default: return .denied
        }
    }

    /// Shows the system prompt the first time; afterwards the answer comes from Settings.
    func requestAccess() async {
        errorMessage = nil
        do {
            let granted = try await store.requestFullAccessToReminders()
            access = granted ? .granted : Self.currentAccess()
        } catch {
            access = Self.currentAccess()
            if access != .granted { errorMessage = "تعذّر طلب الإذن. حاول مرة أخرى." }
        }
        if access == .granted { loadLists() }
    }

    /// The reminder lists, by name. All are chosen the first time.
    func loadLists() {
        let calendars = store.calendars(for: .reminder)
        lists = calendars
            .map { AppleRemindersImport.List(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let ids = Set(lists.map(\.id))
        selected = selected.intersection(ids)
        if selected.isEmpty { selected = ids }
    }

    /// Reads the chosen lists and adds what is new. `userId` keys what is remembered, so another
    /// account on this device starts fresh.
    func importSelected(context: ModelContext, sync: SyncEngine, userId: UUID?) async {
        guard access == .granted, !isWorking else { return }
        let chosen = lists.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else {
            errorMessage = "اختر قائمة واحدة على الأقل."
            return
        }
        isWorking = true
        errorMessage = nil
        resultMessage = nil
        defer { isWorking = false }

        let items = await fetchReminders(in: Set(chosen.map(\.id)))
        let refs = RemindersImportRefs(userId: userId)
        let projects = (try? context.fetch(FetchDescriptor<ProjectItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let liveProjects = Set(projects.map(\.id))
        let knownProjects = refs.projects.filter { liveProjects.contains($0.value) }
        let firstOrder = (projects.map(\.sortOrder).max() ?? -1) + 1

        let plan = AppleRemindersImport.plan(items: items, lists: chosen, knownTasks: refs.tasks, knownProjects: knownProjects,
                                             timeZone: .current, now: Date(), firstProjectSortOrder: firstOrder)
        do {
            try Store(context: context, sync: sync).insertImported(projects: plan.projects, tasks: plan.tasks, reminders: plan.reminders)
        } catch {
            errorMessage = "تعذّر حفظ المهام على هذا الجهاز. حاول مرة أخرى."
            return
        }
        refs.remember(tasks: plan.taskRefs, projects: plan.projectRefs)
        resultMessage = AppleRemindersImport.summary(plan, locale: ZimamLocale.current)
    }

    /// EventKit calls back on its own queue; the reminders are turned into plain values there.
    private func fetchReminders(in listIds: Set<String>) async -> [AppleRemindersImport.Item] {
        let store = self.store
        let calendars = store.calendars(for: .reminder).filter { listIds.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map(EventKitReminders.item(from:))
                continuation.resume(returning: items)
            }
        }
    }
}

/// EventKit's reminders as `AppleRemindersImport` values. Not tied to an actor: EventKit
/// hands the reminders over on a queue of its own.
enum EventKitReminders {
    static func item(from reminder: EKReminder) -> AppleRemindersImport.Item {
        let external: String? = reminder.calendarItemExternalIdentifier
        let id: String
        if let external, !external.isEmpty {
            id = external
        } else {
            id = reminder.calendarItemIdentifier
        }
        let due = reminder.dueDateComponents
        let dueDate = due.flatMap { components -> Date? in
            var calendar = components.calendar ?? Calendar(identifier: .gregorian)
            calendar.timeZone = components.timeZone ?? .current
            return calendar.date(from: components)
        }
        let alarms = (reminder.alarms ?? []).compactMap { alarm -> Date? in
            guard alarm.structuredLocation == nil else { return nil }
            if let absolute = alarm.absoluteDate { return absolute }
            return dueDate?.addingTimeInterval(alarm.relativeOffset)
        }
        let title: String? = reminder.title
        return AppleRemindersImport.Item(
            externalId: id,
            listId: reminder.calendar?.calendarIdentifier ?? "",
            title: title ?? "",
            notes: reminder.notes,
            url: reminder.url,
            due: due,
            priority: reminder.priority,
            isCompleted: reminder.isCompleted,
            completedAt: reminder.completionDate,
            alarms: alarms,
            repeatRule: reminder.recurrenceRules?.first.flatMap(rule(from:))
        )
    }

    static func rule(from rule: EKRecurrenceRule) -> AppleRemindersImport.Repeat? {
        let frequency: Recurrence.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return nil
        }
        let days = rule.daysOfTheWeek ?? []
        // Zimam repeats on weekdays only weekly, and not «the first Monday», a day of the month or a set position.
        let isExact = days.allSatisfy { $0.weekNumber == 0 }
            && (days.isEmpty || frequency == .weekly)
            && (rule.daysOfTheMonth ?? []).isEmpty
            && (rule.daysOfTheYear ?? []).isEmpty
            && (rule.weeksOfTheYear ?? []).isEmpty
            && (rule.monthsOfTheYear ?? []).isEmpty
            && (rule.setPositions ?? []).isEmpty
        let count = rule.recurrenceEnd.flatMap { $0.occurrenceCount > 0 ? $0.occurrenceCount : nil }
        return AppleRemindersImport.Repeat(
            frequency: frequency,
            interval: rule.interval,
            weekdays: days.compactMap { Weekday(rawValue: $0.dayOfTheWeek.rawValue) },
            count: count,
            until: rule.recurrenceEnd?.endDate,
            isExact: isExact
        )
    }
}

/// What was imported from Reminders, per account, in this device's UserDefaults: each reminder's
/// external identifier with the task it became, and each list with its project. Kept after a task
/// is deleted in Zimam, so a deleted task does not come back on the next import.
struct RemindersImportRefs {
    private let tasksKey: String
    private let projectsKey: String
    private let defaults: UserDefaults

    init(userId: UUID?, defaults: UserDefaults = .standard) {
        let account = userId?.uuidString.lowercased() ?? "local"
        tasksKey = "import.appleReminders.tasks.\(account)"
        projectsKey = "import.appleReminders.lists.\(account)"
        self.defaults = defaults
    }

    var tasks: [String: UUID] { read(tasksKey) }
    var projects: [String: UUID] { read(projectsKey) }

    func remember(tasks newTasks: [String: UUID], projects newProjects: [String: UUID]) {
        write(tasks.merging(newTasks) { _, new in new }, to: tasksKey)
        write(projects.merging(newProjects) { _, new in new }, to: projectsKey)
    }

    private func read(_ key: String) -> [String: UUID] {
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return stored.compactMapValues(UUID.init(uuidString:))
    }

    private func write(_ refs: [String: UUID], to key: String) {
        defaults.set(refs.mapValues(\.uuidString), forKey: key)
    }
}
