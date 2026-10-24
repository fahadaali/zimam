import Foundation
import Observation
import os
import SwiftData
import ZimamKit

/// Sends local edits to the API, then applies what changed on the server.
/// Runs on launch, when the app returns to the foreground, shortly after each edit, when the
/// realtime channel says the server has changes this device has not pulled, when the network
/// comes back, and again by itself after a sync that failed (`scheduleRetry`).
@MainActor
@Observable
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    /// The sync in progress. A call made meanwhile waits for it (`sync()`).
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var runAgain = false
    /// The next try after a failed sync, and how many failed in a row.
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    /// Whether the sync in progress changed what the app shows, so the listeners refresh once,
    /// and not after a sync that found nothing new.
    @ObservationIgnored private var savedChanges = false
    @ObservationIgnored private var realtime: RealtimeChannel?
    @ObservationIgnored private var remoteSync: Task<Void, Never>?
    /// Bumped by `reset()`. A sync started before it stops at its next step instead of writing
    /// the previous account's records, or its cursor, into the wiped store.
    @ObservationIgnored private var generation = 0
    /// Called when the server no longer accepts the session.
    @ObservationIgnored var onUnauthorized: (() -> Void)?
    /// Called after local edits and after each sync that changed something, so what depends on
    /// the data (scheduled notifications, the widgets) can refresh.
    @ObservationIgnored var onDataChanged: (@MainActor () -> Void)?

    private static let cursorKey = "sync.cursor"
    /// What the cursor was earned with (`cursorBasis`). Pulls without saved places moved past
    /// them, so asking for more starts once from zero.
    private static let includesKey = "sync.includes"
    /// Raised when the way a pull is applied changes, so that a pull from zero puts right what an
    /// older way left. 2: a deletion the server turned down used to stay hidden, or be removed, on
    /// this device alone; every live record comes back with its latest version (`reveal`).
    private static let applyVersion = 2
    /// The pull's includes (`APIClient.pullIncludes`) and `applyVersion`: a cursor earned with
    /// another starts once from zero.
    private static var cursorBasis: String { "\(APIClient.pullIncludes);apply=\(applyVersion)" }
    /// Set before a wipe and cleared once it is saved. While set, nothing is sent, so a wipe
    /// that failed at sign-out never lets the next account push this one's records.
    private static let wipePendingKey = "sync.wipePending"
    private static let logger = Logger(subsystem: "app.zimam.ios", category: "sync")

    /// The account changed under a sync in progress.
    private struct Superseded: Error {}

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    /// Kept in the App Group next to the store it describes. The store moved there
    /// empty, so the cursor starts from zero with it and the first sync refills it.
    private var cursor: Int64 {
        get {
            guard ZimamShared.defaults.string(forKey: Self.includesKey) == Self.cursorBasis else { return 0 }
            return Int64(ZimamShared.defaults.integer(forKey: Self.cursorKey))
        }
        set {
            ZimamShared.defaults.set(Int(newValue), forKey: Self.cursorKey)
            ZimamShared.defaults.set(Self.cursorBasis, forKey: Self.includesKey)
        }
    }

    /// Tells listeners that a local edit was saved. `Store` calls this after each commit.
    func noteLocalChange() {
        onDataChanged?()
    }

    /// Syncs soon, folding a burst of edits into one request.
    func scheduleSync() {
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// Returns once the edits saved before the call are pushed and the pull after them is
    /// applied, or once that sync failed. A call made during a sync waits for it, and for the
    /// round it adds for this call, so a server request made next finds the record there.
    func sync() async {
        if let running {
            runAgain = true
            await running.value
            return
        }
        let run = Task { await runRounds() }
        running = run
        await run.value
    }

    /// `sync()`, waited for at most `limit`: for an intent or a background wake, which the system
    /// may end first. True if it ended in time; if not, it goes on in its own task while the app
    /// still runs. Cancelling a caller of `sync()` does not end its wait, so the time is kept here.
    func sync(waitingAtMost limit: Duration) async -> Bool {
        let (ended, end) = AsyncStream<Bool>.makeStream()
        Task {
            await sync()
            end.yield(true)
        }
        let timer = Task {
            try await Task.sleep(for: limit)
            end.yield(false)
        }
        defer { timer.cancel() }
        for await inTime in ended { return inTime }
        return false
    }

    /// The sync itself, in a task of its own: cancelling a caller (a scheduled sync replaced by
    /// a newer edit, a view that closed) does not cut its push or pull short.
    private func runRounds() async {
        defer { running = nil }
        guard wipeIfPending() else {
            lastError = "تعذّرت المزامنة، وستُعاد المحاولة تلقائياً."
            scheduleRetry(wipeOnly: true)
            return
        }
        isSyncing = true
        savedChanges = false
        defer { isSyncing = false }
        repeat {
            runAgain = false
            let started = generation
            do {
                try await push(started)
                try await pull(started)
                lastSyncedAt = Date()
                lastError = nil
                failures = 0
                retry?.cancel()
                retry = nil
            } catch is Superseded {
                // Signed out mid-sync: the new account's request, if any, runs from scratch.
                continue
            } catch let error as APIError where error.isUnauthorized {
                onUnauthorized?()
                return
            } catch {
                // Signed out meanwhile: as for `Superseded`, no retry for the previous account,
                // which would go out without a token and whose 401 could sign out the next one.
                guard generation == started else { continue }
                lastError = "تعذّرت المزامنة، وستُعاد المحاولة تلقائياً."
                scheduleRetry()
                // Batches and pages saved before the failure still count below.
                break
            }
        } while runAgain
        if savedChanges { onDataChanged?() }
    }

    /// After a failure: tries again by itself, 5 seconds later, then twice as long each time up
    /// to 5 minutes, until a sync succeeds. An edit, a return to the app or the network coming
    /// back tries sooner. A retry stops if the account changed before it (`reset`). After a wipe
    /// that failed (`wipeOnly`), only the wipe is tried again, as it follows a sign-out: nothing
    /// is sent, and the next sync asked for (a sign-in, an edit, a return) goes on from there.
    private func scheduleRetry(wipeOnly: Bool = false) {
        failures += 1
        let seconds = min(300, 5 << min(failures - 1, 6))
        let account = generation
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.generation == account else { return }
            if !wipeOnly {
                await self.sync()
            } else if self.wipeIfPending() {
                self.failures = 0
                self.onDataChanged?()
            } else {
                self.scheduleRetry(wipeOnly: true)
            }
        }
    }

    // MARK: Realtime

    /// Opens the realtime channel. Call while the app is active and signed in.
    func startRealtime() {
        if realtime == nil {
            let channel = RealtimeChannel(api: api)
            channel.onChanged = { [weak self] seq in self?.noteServerChange(seq: seq) }
            channel.onResync = { [weak self] in
                guard let self else { return }
                Task { await self.sync() }
            }
            realtime = channel
        }
        realtime?.start()
    }

    /// Closes the realtime channel: in the background and after signing out.
    func stopRealtime() {
        realtime?.stop()
        remoteSync?.cancel()
    }

    /// The server has changes up to `seq`. Pulls unless this device already has them; a sync
    /// in progress (often this device's own push, whose pull reaches `seq`) is waited out first.
    func noteServerChange(seq: Int64) {
        guard seq > cursor else { return }
        remoteSync?.cancel()
        remoteSync = Task {
            try? await Task.sleep(for: .milliseconds(300))
            while isSyncing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled, seq > cursor else { return }
            await sync()
        }
    }

    /// Removes every local record and starts the next sync from scratch. A sync in progress
    /// stops at its next step. If the wipe fails it is retried before the next sync sends
    /// anything (`wipeIfPending`).
    func reset() {
        generation += 1
        scheduled?.cancel()
        retry?.cancel()
        retry = nil
        failures = 0
        stopRealtime()
        ZimamShared.defaults.set(true, forKey: Self.wipePendingKey)
        wipeIfPending()
        onDataChanged?()
    }

    /// Finishes a pending wipe. False while it still fails; the store is left as it was.
    @discardableResult
    func wipeIfPending() -> Bool {
        guard ZimamShared.defaults.bool(forKey: Self.wipePendingKey) else { return true }
        do {
            try context.delete(model: ReminderItem.self)
            try context.delete(model: PlaceItem.self)
            try context.delete(model: TaskItem.self)
            try context.delete(model: SectionItem.self)
            try context.delete(model: ProjectItem.self)
            try context.save()
        } catch {
            context.rollback()
            Self.logger.error("Wiping local data failed: \(error.localizedDescription)")
            return false
        }
        cursor = 0
        ZimamShared.defaults.set(false, forKey: Self.wipePendingKey)
        return true
    }

    // MARK: Push

    private struct Outgoing {
        let mutation: Mutation
        /// True when the result changed what the app shows (a record removed or shown again).
        let settle: (MutationResult) -> Bool
    }

    private func push(_ started: Int) async throws {
        let projects = try context.fetch(FetchDescriptor<ProjectItem>(predicate: #Predicate { $0.isDirty }))
        let sections = try context.fetch(FetchDescriptor<SectionItem>(predicate: #Predicate { $0.isDirty }))
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isDirty }))
        let reminders = try context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.isDirty }))
        let places = try context.fetch(FetchDescriptor<PlaceItem>(predicate: #Predicate { $0.isDirty }))

        // Creations and edits first, parents before children; deletions last. Places go before
        // the reminders that name them, which the server unlinks from a place it does not know.
        var upserts: [Outgoing] = []
        var deletes: [Outgoing] = []
        for place in places where !place.pendingDelete {
            upserts.append(outgoing(place, .upsert(.place(place.record))))
        }
        for project in projects.sorted(by: { $0.kindRaw == "folder" && $1.kindRaw != "folder" }) {
            if project.pendingDelete {
                deletes.append(outgoing(project, .delete(.project, id: project.id, updatedAt: project.updatedAt)))
            } else {
                upserts.append(outgoing(project, .upsert(.project(project.record))))
            }
        }
        for section in sections where !section.pendingDelete {
            upserts.append(outgoing(section, .upsert(.section(section.record))))
        }
        let sent = tasks.filter { !$0.pendingDelete }
        // Parents first; the order only matters with more than one, so the usual single edit
        // does not fetch every task to work it out.
        let depth = try sent.count > 1 ? taskDepths() : [:]
        for task in sent.sorted(by: { depth[$0.id, default: 0] < depth[$1.id, default: 0] }) {
            upserts.append(outgoing(task, .upsert(.task(task.record))))
        }
        for reminder in reminders {
            if reminder.pendingDelete {
                deletes.append(outgoing(reminder, .delete(.reminder, id: reminder.id, updatedAt: reminder.updatedAt)))
            } else {
                upserts.append(outgoing(reminder, .upsert(.reminder(reminder.record))))
            }
        }
        for task in tasks where task.pendingDelete {
            deletes.append(outgoing(task, .delete(.task, id: task.id, updatedAt: task.updatedAt)))
        }
        for section in sections where section.pendingDelete {
            deletes.append(outgoing(section, .delete(.section, id: section.id, updatedAt: section.updatedAt)))
        }
        for place in places where place.pendingDelete {
            deletes.append(outgoing(place, .delete(.place, id: place.id, updatedAt: place.updatedAt)))
        }

        let all = upserts + deletes
        var start = 0
        while start < all.count {
            let batch = Array(all[start..<min(start + APIClient.maxPushBatch, all.count)])
            let results = try await api.push(batch.map(\.mutation))
            // After a reset these records are deleted: settling them would touch freed models.
            guard generation == started else { throw Superseded() }
            for (item, result) in zip(batch, results) {
                if item.settle(result) { savedChanges = true }
            }
            try context.save()
            start += batch.count
        }
    }

    /// Wraps a mutation with what to do with its result. A record edited or deleted while the
    /// request was in flight stays dirty and goes out on the next round.
    private func outgoing<Item: SyncedItem>(_ item: Item, _ mutation: Mutation) -> Outgoing {
        let sentVersion = item.updatedAt
        let sentDelete: Bool
        if case .delete = mutation { sentDelete = true } else { sentDelete = false }
        return Outgoing(mutation: mutation) { [context] result in
            // As it was sent: neither edited nor deleted since.
            let unchanged = item.updatedAt == sentVersion && item.pendingDelete == sentDelete
            switch result.status {
            case .applied:
                if sentDelete {
                    // What its deletion hid goes with the server's, in the pull that follows.
                    Self.leaveSection(item, in: context)
                    context.delete(item)
                } else if unchanged {
                    item.isDirty = false
                    item.syncError = nil
                }
                return false
            case .stale:
                if sentDelete {
                    // Edited elsewhere after it was deleted here: the later edit wins, as on the
                    // web, and the pull that follows brings it. It shows again, with what it hid.
                    Self.unhide(item, in: context)
                    item.isDirty = false
                    return true
                }
                // The server's newer version arrives with the pull that follows.
                if unchanged { item.isDirty = false }
                return false
            case .gone:
                Self.leaveSection(item, in: context)
                context.delete(item)
                return true
            case .forbidden, .invalid:
                if sentDelete && result.status == .invalid {
                    // The server never had it, so nothing it has hangs from it (what was never
                    // sent goes out as its own deletion): nothing is left to send.
                    context.delete(item)
                    return false
                }
                if sentDelete {
                    // Not this user's to delete (a viewer's task): it stays, here as on the server.
                    Self.unhide(item, in: context)
                } else if !unchanged {
                    return false
                }
                item.isDirty = false
                item.syncError = result.message ?? result.status.rawValue
                return sentDelete
            }
        }
    }

    private func taskDepths() throws -> [UUID: Int] {
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let parents = Dictionary(all.map { ($0.id, $0.parentId) }, uniquingKeysWith: { first, _ in first })
        var depths: [UUID: Int] = [:]
        for task in all {
            var depth = 0
            var parent = task.parentId
            while let id = parent, depth < 20 {
                depth += 1
                parent = parents[id] ?? nil
            }
            depths[task.id] = depth
        }
        return depths
    }

    // MARK: Pull

    private func pull(_ started: Int) async throws {
        var hasMore = true
        while hasMore {
            let page = try await api.pull(cursor: cursor)
            guard generation == started else { throw Superseded() }
            // If the lookup fails, nothing of the page is applied and the next pull tries it
            // again whole, rather than insert records it could not find and duplicate them.
            var records = try localRecords(for: page.changes)
            var changed = false
            for change in page.changes {
                if apply(change, to: &records) { changed = true }
            }
            try context.save()
            if changed { savedChanges = true }
            cursor = page.cursor
            hasMore = page.hasMore
        }
    }

    /// The local records a page's changes touch, by id.
    private struct PageRecords {
        var projects: [UUID: ProjectItem] = [:]
        var sections: [UUID: SectionItem] = [:]
        var tasks: [UUID: TaskItem] = [:]
        var reminders: [UUID: ReminderItem] = [:]
        var places: [UUID: PlaceItem] = [:]
    }

    /// Looks up the page's records that exist here: one fetch per kind, not one per change.
    private func localRecords(for changes: [SyncChange]) throws -> PageRecords {
        func ids(_ kind: EntityKind) -> [UUID] { changes.filter { $0.entity == kind }.map(\.id) }
        var records = PageRecords()
        let projectIds = ids(.project)
        if !projectIds.isEmpty {
            let found = try context.fetch(FetchDescriptor<ProjectItem>(predicate: #Predicate { projectIds.contains($0.id) }))
            for item in found { records.projects[item.id] = item }
        }
        let sectionIds = ids(.section)
        if !sectionIds.isEmpty {
            let found = try context.fetch(FetchDescriptor<SectionItem>(predicate: #Predicate { sectionIds.contains($0.id) }))
            for item in found { records.sections[item.id] = item }
        }
        let taskIds = ids(.task)
        if !taskIds.isEmpty {
            let found = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { taskIds.contains($0.id) }))
            for item in found { records.tasks[item.id] = item }
        }
        let reminderIds = ids(.reminder)
        if !reminderIds.isEmpty {
            let found = try context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { reminderIds.contains($0.id) }))
            for item in found { records.reminders[item.id] = item }
        }
        let placeIds = ids(.place)
        if !placeIds.isEmpty {
            let found = try context.fetch(FetchDescriptor<PlaceItem>(predicate: #Predicate { placeIds.contains($0.id) }))
            for item in found { records.places[item.id] = item }
        }
        return records
    }

    /// Applies one change. `records` follows along, so a record inserted or deleted earlier in
    /// the page is found or missed by the changes after it. True when anything here changed;
    /// false for an echo of this device's own edit, or a local edit newer than the server's.
    private func apply(_ change: SyncChange, to records: inout PageRecords) -> Bool {
        switch change.record {
        case .project(let record)?:
            if let local = records.projects[change.id] {
                guard !keepsLocal(local, over: record.updatedAt) else { return false }
                let changed = reveal(local) || local.record != record
                local.apply(record)
                return changed
            }
            let item = ProjectItem(record, dirty: false)
            context.insert(item)
            records.projects[change.id] = item
        case .section(let record)?:
            if let local = records.sections[change.id] {
                guard !keepsLocal(local, over: record.updatedAt) else { return false }
                let changed = reveal(local) || local.record != record
                local.apply(record)
                return changed
            }
            let item = SectionItem(record, dirty: false)
            context.insert(item)
            records.sections[change.id] = item
        case .task(let record)?:
            if let local = records.tasks[change.id] {
                guard !keepsLocal(local, over: record.updatedAt) else { return false }
                let changed = reveal(local) || local.record != record
                local.apply(record)
                return changed
            }
            let item = TaskItem(record, dirty: false)
            context.insert(item)
            records.tasks[change.id] = item
        case .reminder(let record)?:
            if let local = records.reminders[change.id] {
                guard !keepsLocal(local, over: record.updatedAt) else { return false }
                let changed = reveal(local) || local.record != record
                local.apply(record)
                return changed
            }
            let item = ReminderItem(record, dirty: false)
            context.insert(item)
            records.reminders[change.id] = item
        case .place(let record)?:
            if let local = records.places[change.id] {
                guard !keepsLocal(local, over: record.updatedAt) else { return false }
                let changed = reveal(local) || local.record != record
                local.apply(record)
                return changed
            }
            let item = PlaceItem(record, dirty: false)
            context.insert(item)
            records.places[change.id] = item
        case .comment?:
            return false // Comments are shown from the API when a task opens; not stored yet.
        case nil:
            switch change.entity {
            case .project: return remove(records.projects.removeValue(forKey: change.id))
            case .section:
                guard let local = records.sections.removeValue(forKey: change.id) else { return false }
                // Its tasks come with the deletion too, but one edited here keeps its own version.
                Self.leaveSection(local, in: context)
                context.delete(local)
                return true
            case .task: return remove(records.tasks.removeValue(forKey: change.id))
            case .reminder: return remove(records.reminders.removeValue(forKey: change.id))
            case .place: return remove(records.places.removeValue(forKey: change.id))
            case .comment: return false
            }
        }
        return true
    }

    /// A record a deletion still hides, about to take the server's version: the server kept it,
    /// edited after that deletion, so it shows again with what the deletion hid. True if it was hidden.
    private func reveal(_ local: some SyncedItem) -> Bool {
        guard local.pendingDelete else { return false }
        Self.unhide(local, in: context)
        return true
    }

    private func remove<Item: PersistentModel>(_ local: Item?) -> Bool {
        guard let local else { return false }
        context.delete(local)
        return true
    }

    /// A local edit newer than the server's version wins; it goes out on the next push. So does a
    /// deletion not sent yet over the same version: the echo of the record's own edit, sent before
    /// a parent's deletion hid it, does not bring it back.
    private func keepsLocal(_ item: some SyncedItem, over serverVersion: Int64) -> Bool {
        item.isDirty && (item.updatedAt > serverVersion || (item.pendingDelete && item.updatedAt >= serverVersion))
    }

    // MARK: Deletions the server turned down

    /// What `Store.delete` hid along with a task or project and left to the server's deletion:
    /// hidden but not dirty, so never sent on their own.
    private struct Hidden {
        var tasks: [TaskItem] = []
        var sections: [SectionItem] = []
        var reminders: [ReminderItem] = []
    }

    /// A task's subtasks (not those deleted on their own, which are dirty) and the reminders of
    /// the whole tree; a project's tasks, sections and the reminders of those tasks. Only records
    /// waiting for a deletion are read, not the whole store, once for each deletion turned down.
    private static func hiddenWith(_ item: some SyncedItem, in context: ModelContext) -> Hidden {
        var found = Hidden()
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.pendingDelete }))) ?? []
        var treeIds: Set<UUID> = []
        if let task = item as? TaskItem {
            found.tasks = hiddenSubtasks(below: [task.id], in: tasks)
            treeIds.insert(task.id)
        } else if let project = item as? ProjectItem {
            let id = project.id
            let waiting = Set(tasks.map(\.id))
            // The project's hidden tasks whose parent is not hidden as well: the others are reached
            // from their parent, unless that parent was deleted on its own.
            let roots = tasks.filter { task in
                guard task.projectId == id, !task.isDirty else { return false }
                return task.parentId.map { !waiting.contains($0) } ?? true
            }
            found.tasks = roots + hiddenSubtasks(below: roots.map(\.id), in: tasks)
            found.sections = ((try? context.fetch(FetchDescriptor<SectionItem>(
                predicate: #Predicate { $0.pendingDelete && !$0.isDirty }))) ?? [])
                .filter { $0.projectId == id }
        } else {
            return found
        }
        treeIds.formUnion(found.tasks.map(\.id))
        found.reminders = ((try? context.fetch(FetchDescriptor<ReminderItem>(
            predicate: #Predicate { $0.pendingDelete && !$0.isDirty }))) ?? [])
            .filter { treeIds.contains($0.taskId) }
        return found
    }

    /// Hidden, clean subtasks under `roots`, at any depth. `tasks` holds at least the hidden ones.
    private static func hiddenSubtasks(below roots: [UUID], in tasks: [TaskItem]) -> [TaskItem] {
        let children = Dictionary(grouping: tasks, by: \.parentId)
        var found: [TaskItem] = []
        var seen = Set(roots)
        var queue = roots
        while let id = queue.popLast() {
            for child in children[id] ?? [] where child.pendingDelete && !child.isDirty {
                guard seen.insert(child.id).inserted else { continue }
                found.append(child)
                queue.append(child.id)
            }
        }
        return found
    }

    /// Shows a record again, with what its deletion hid.
    private static func unhide(_ item: some SyncedItem, in context: ModelContext) {
        let hidden = hiddenWith(item, in: context)
        for task in hidden.tasks { task.pendingDelete = false }
        for section in hidden.sections { section.pendingDelete = false }
        for reminder in hidden.reminders { reminder.pendingDelete = false }
        item.pendingDelete = false
    }

    /// A section gone from the server: the tasks still in it here leave it, as its deletion left
    /// them there, so an edit to one is not refused for naming it. Nothing for other records.
    private static func leaveSection(_ item: some SyncedItem, in context: ModelContext) {
        guard let section = item as? SectionItem else { return }
        let id: UUID? = section.id
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.sectionId == id }))) ?? []
        for task in tasks { task.sectionId = nil }
    }
}

/// `Store` asks the engine to send edits soon and tells it that the data changed.
extension SyncEngine: SyncScheduling {}
