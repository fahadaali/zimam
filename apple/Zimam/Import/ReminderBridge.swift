import EventKit
import Foundation
import Observation
import os
import SwiftData
import ZimamKit

/// «ذكرني …» to Siri without naming Zimam. Apple lets no app be Siri's reminders app, so Siri
/// saves such a reminder in Apple Reminders; when this is on, Zimam brings every open reminder of
/// the chosen list over to its inbox, with its day, time, alarms and repeat, reads a prayer left in
/// the title («بعد العصر», `SpokenTime`), and then removes it from Reminders.
///
/// - It runs when the app opens or comes back, while it runs (`EKEventStoreChanged`), and in the
///   background (`BackgroundRefresh`). Closed for long, a reminder waits in Reminders, whose alarm
///   still fires, until the next run.
/// - A reminder is removed from Reminders only after its task is saved. One with an alarm at a
///   place stays there: Zimam does not read places from Reminders.
/// - The same reminder becomes the same task on every device (`bridgedTaskId`), so two devices
///   bringing it over at once make one task.
/// - It is set per device. Brought-over reminders are remembered with the imported ones
///   (`RemindersImportRefs`), so a later import does not add them again.
@MainActor
@Observable
final class ReminderBridge {
    static let shared = ReminderBridge()

    /// On for this device.
    var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.onKey)
            if isOn { Task { await run() } }
        }
    }
    /// The Reminders list Siri writes to; nil is Reminders' default list.
    var listId: String? {
        didSet { UserDefaults.standard.set(listId, forKey: Self.listKey) }
    }
    private(set) var isRunning = false
    /// What the last run did, in Arabic.
    private(set) var lastResult: String?

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var sync: SyncEngine?
    @ObservationIgnored private var session: SessionStore?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var storage: EKEventStore?

    private static let onKey = "bridge.reminders.on"
    private static let listKey = "bridge.reminders.list"
    private static let logger = Logger(subsystem: "app.zimam.ios", category: "bridge")

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.onKey)
        listId = UserDefaults.standard.string(forKey: Self.listKey)
    }

    private var store: EKEventStore {
        if let storage { return storage }
        let made = EKEventStore()
        storage = made
        return made
    }

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status == .denied || status == .restricted || status == .writeOnly
    }

    /// Called at launch with what the bridge writes through. Starts listening for changes in
    /// Reminders while the app runs.
    func start(context: ModelContext, sync: SyncEngine, session: SessionStore) {
        self.context = context
        self.sync = sync
        self.session = session
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await ReminderBridge.shared.run() }
        }
    }

    /// Asks for full access to Reminders (to read and remove what is brought over). True if allowed.
    func requestAccess() async -> Bool {
        if hasAccess { return true }
        _ = try? await store.requestFullAccessToReminders()
        return hasAccess
    }

    /// The user's reminder lists, by name, with the default one marked.
    func lists() -> [(id: String, title: String, isDefault: Bool)] {
        guard hasAccess else { return [] }
        let defaultId = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder)
            .map { (id: $0.calendarIdentifier, title: $0.title, isDefault: $0.calendarIdentifier == defaultId) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Brings the list's open reminders over. Does nothing when off, signed out, without access,
    /// or already running.
    func run() async {
        guard isOn, hasAccess, !isRunning, let context, let sync, let session, session.isSignedIn else { return }
        let calendar = listId.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewReminders()
        guard let calendar else { return }
        isRunning = true
        defer { isRunning = false }

        let found = await openReminders(in: calendar)
        let movable = found.filter { !$0.hasPlace }
        guard !movable.isEmpty else { return }

        let userId = session.user?.id
        let refs = RemindersImportRefs(userId: userId)
        let list = AppleRemindersImport.List(id: calendar.calendarIdentifier, title: calendar.title)
        let plan = AppleRemindersImport.plan(
            items: movable.map(\.item), lists: [list], knownTasks: refs.tasks, knownProjects: [:],
            timeZone: .current, now: Date(),
            bridge: .init(userId: userId, schedule: SharedSettings.prayerSchedule()))

        func existsHere(_ id: UUID) -> Bool {
            var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return ((try? context.fetchCount(descriptor)) ?? 0) > 0
        }
        // A task another device brought over and this one has pulled is not added twice.
        let fresh = plan.tasks.filter { !existsHere($0.id) }
        let freshIds = Set(fresh.map(\.id))
        do {
            try Store(context: context, sync: sync).insertImported(
                projects: [], tasks: fresh, reminders: plan.reminders.filter { freshIds.contains($0.taskId) })
        } catch {
            Self.logger.error("Bringing reminders over failed: \(error.localizedDescription, privacy: .public)")
            lastResult = "تعذّر حفظ التذكيرات في زمام. ستُنقل في المرة القادمة."
            return
        }
        refs.remember(tasks: plan.taskRefs, projects: [:])

        // Out of Reminders, so its alarm does not ring twice: only a reminder whose bridged task is
        // now in Zimam (saved here, or by another device). One imported before (the import keeps
        // Reminders as it is) or whose task was since deleted stays in Reminders.
        let saved = Set(movable.map(\.item.externalId).filter {
            existsHere(AppleRemindersImport.bridgedTaskId(userId: userId, externalId: $0))
        })
        var removed = 0
        for reminder in movable where saved.contains(reminder.item.externalId) {
            guard let item = store.calendarItem(withIdentifier: reminder.localId) as? EKReminder else { continue }
            do {
                try store.remove(item, commit: false)
                removed += 1
            } catch {
                Self.logger.error("Removing a reminder failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        try? store.commit()
        if fresh.isEmpty {
            lastResult = nil
        } else {
            lastResult = ArabicCount.tasks(fresh.count, locale: ZimamLocale.current) + " نُقلت من التذكيرات."
        }
        Self.logger.info("Brought \(fresh.count, privacy: .public) reminders over, removed \(removed, privacy: .public)")
    }

    /// EventKit hands the reminders over on a queue of its own; they become plain values there.
    private func openReminders(in calendar: EKCalendar) async -> [BridgedReminder] {
        let store = self.store
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        return await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { @Sendable reminders in
                let found = (reminders ?? []).map(BridgedReminder.init(reminder:))
                continuation.resume(returning: found)
            }
        }
    }
}

/// One reminder as plain values, made on EventKit's queue (so not tied to the main actor).
nonisolated private struct BridgedReminder: Sendable {
    let item: AppleRemindersImport.Item
    /// `calendarItemIdentifier`, to remove it afterwards.
    let localId: String
    /// An alarm at a place («لما أوصل البيت»): left in Reminders.
    let hasPlace: Bool

    init(reminder: EKReminder) {
        item = EventKitReminders.item(from: reminder)
        localId = reminder.calendarItemIdentifier
        hasPlace = (reminder.alarms ?? []).contains { $0.structuredLocation != nil }
    }
}
