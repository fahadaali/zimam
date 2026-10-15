import EventKit
import Foundation
import Observation
import SwiftData
import ZimamKit

/// Imports Apple Calendar events as tasks on the device: the chosen calendars, from today to a few
/// months ahead, each calendar a project (`AppleCalendarImport`). Records go through `Store`, so they
/// sync like any edit. What was imported is remembered per account (`CalendarImportRefs`), so
/// importing again adds only what is new. The permission and the event store are `CalendarEvents`'.
@MainActor
@Observable
final class CalendarImporter {
    /// How far ahead to import, in months.
    static let windows = [1, 3, 6, 12]

    private(set) var calendars: [AppleCalendarImport.CalendarRef] = []
    var selected: Set<String> = []
    var months = 3
    private(set) var isWorking = false
    /// What the last import did, in Arabic.
    private(set) var resultMessage: String?
    private(set) var errorMessage: String?

    private var events: CalendarEvents { .shared }

    var access: CalendarEvents.Access { events.access }

    init() {}

    /// Reads the permission again (it may have changed in Settings) and the calendars when allowed.
    func refresh() {
        events.refresh()
        if access == .granted { loadCalendars() }
    }

    func requestAccess() async {
        errorMessage = nil
        await events.requestAccess()
        errorMessage = events.errorMessage
        if access == .granted { loadCalendars() }
    }

    /// The device's calendars. The first time, all are chosen except subscribed and birthday calendars.
    func loadCalendars() {
        if events.calendars.isEmpty { events.loadCalendars() }
        calendars = events.calendars
        let ids = Set(calendars.map(\.id))
        selected = selected.intersection(ids)
        if selected.isEmpty {
            let own = ids.subtracting(events.subscribedCalendars)
            selected = own.isEmpty ? ids : own
        }
    }

    /// Reads the chosen calendars' events in the window and adds what is new. `userId` keys what is
    /// remembered, so another account on this device starts fresh.
    func importSelected(context: ModelContext, sync: SyncEngine, userId: UUID?) async {
        guard access == .granted, !isWorking else { return }
        let chosen = calendars.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else {
            errorMessage = "اختر تقويماً واحداً على الأقل."
            return
        }
        isWorking = true
        errorMessage = nil
        resultMessage = nil
        defer { isWorking = false }
        // Lets the button show its progress before EventKit reads.
        await Task.yield()

        let window = AppleCalendarImport.window(months: months, now: Date(), timeZone: .current)
        let found = events.occurrences(in: Set(chosen.map(\.id)), from: window.start, to: window.end)
        let refs = CalendarImportRefs(userId: userId)
        let projects = (try? context.fetch(FetchDescriptor<ProjectItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let liveProjects = Set(projects.map(\.id))
        let knownProjects = refs.projects.filter { liveProjects.contains($0.value) }
        let firstOrder = (projects.map(\.sortOrder).max() ?? -1) + 1

        let plan = AppleCalendarImport.plan(events: found.events, calendars: chosen, knownTasks: refs.tasks,
                                            knownProjects: knownProjects, seriesStarts: found.seriesStarts,
                                            timeZone: .current, now: Date(), firstProjectSortOrder: firstOrder)
        do {
            try Store(context: context, sync: sync).insertImported(projects: plan.projects, tasks: plan.tasks, reminders: [])
        } catch {
            errorMessage = "تعذّر حفظ المهام على هذا الجهاز. حاول مرة أخرى."
            return
        }
        refs.remember(tasks: plan.taskRefs, projects: plan.projectRefs)
        resultMessage = AppleCalendarImport.summary(plan, locale: ZimamLocale.current)
    }
}

/// What became a task from Apple Calendar, per account, in this device's UserDefaults: each event
/// key (`AppleCalendarEvent.importKey`, or the series for a repeating task) with its task, and each
/// calendar with its project. Shared by the import and «تحويل إلى مهمة». Kept after a task is deleted
/// in Zimam, so a deleted task does not come back on the next import.
struct CalendarImportRefs {
    private let tasksKey: String
    private let projectsKey: String
    private let defaults: UserDefaults

    init(userId: UUID?, defaults: UserDefaults = .standard) {
        let account = userId?.uuidString.lowercased() ?? "local"
        tasksKey = "import.appleCalendar.events.\(account)"
        projectsKey = "import.appleCalendar.calendars.\(account)"
        self.defaults = defaults
    }

    var tasks: [String: UUID] { read(tasksKey) }
    var projects: [String: UUID] { read(projectsKey) }

    func remember(tasks newTasks: [String: UUID], projects newProjects: [String: UUID]) {
        if !newTasks.isEmpty { write(tasks.merging(newTasks) { _, new in new }, to: tasksKey) }
        if !newProjects.isEmpty { write(projects.merging(newProjects) { _, new in new }, to: projectsKey) }
    }

    private func read(_ key: String) -> [String: UUID] {
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return stored.compactMapValues(UUID.init(uuidString:))
    }

    private func write(_ refs: [String: UUID], to key: String) {
        defaults.set(refs.mapValues(\.uuidString), forKey: key)
    }
}
