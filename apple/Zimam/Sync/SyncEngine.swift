import Foundation
import Observation
import os
import SwiftData
import ZimamKit

/// Sends local edits to the API, then applies what changed on the server.
/// Runs on launch, when the app returns to the foreground, shortly after each edit,
/// and when the realtime channel says the server has changes this device has not pulled.
@MainActor
@Observable
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var runAgain = false
    @ObservationIgnored private var realtime: RealtimeChannel?
    @ObservationIgnored private var remoteSync: Task<Void, Never>?
    /// Bumped by `reset()`. A sync started before it stops at its next step instead of writing
    /// the previous account's records, or its cursor, into the wiped store.
    @ObservationIgnored private var generation = 0
    /// Called when the server no longer accepts the session.
    @ObservationIgnored var onUnauthorized: (() -> Void)?
    /// Called after local edits and after each sync, so what depends on the data
    /// (scheduled notifications) can refresh.
    @ObservationIgnored var onDataChanged: (@MainActor () -> Void)?

    private static let cursorKey = "sync.cursor"
    /// What the cursor was earned with (`APIClient.pullIncludes`). Pulls without saved places
    /// moved past them, so asking for more starts once from zero.
    private static let includesKey = "sync.includes"
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
            guard ZimamShared.defaults.string(forKey: Self.includesKey) == APIClient.pullIncludes else { return 0 }
            return Int64(ZimamShared.defaults.integer(forKey: Self.cursorKey))
        }
        set {
            ZimamShared.defaults.set(Int(newValue), forKey: Self.cursorKey)
            ZimamShared.defaults.set(APIClient.pullIncludes, forKey: Self.includesKey)
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

    func sync() async {
        guard !isSyncing else {
            runAgain = true
            return
        }
        guard wipeIfPending() else {
            lastError = "تعذّرت المزامنة، وستُعاد المحاولة تلقائياً."
            onDataChanged?()
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            runAgain = false
            let started = generation
            do {
                try await push(started)
                try await pull(started)
                lastSyncedAt = Date()
                lastError = nil
            } catch is Superseded {
                // Signed out mid-sync: the new account's request, if any, runs from scratch.
                continue
            } catch let error as APIError where error.isUnauthorized {
                onUnauthorized?()
                return
            } catch {
                lastError = "تعذّرت المزامنة، وستُعاد المحاولة تلقائياً."
                onDataChanged?()
                return
            }
        } while runAgain
        onDataChanged?()
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
        let settle: (MutationResult) -> Void
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
        let depth = try taskDepths()
        for task in tasks.sorted(by: { depth[$0.id, default: 0] < depth[$1.id, default: 0] }) where !task.pendingDelete {
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
            for (item, result) in zip(batch, results) { item.settle(result) }
            try context.save()
            start += batch.count
        }
    }

    /// Wraps a mutation with what to do with its result. An edit made while the
    /// request was in flight keeps the record dirty for the next round.
    private func outgoing<Item: SyncedItem>(_ item: Item, _ mutation: Mutation) -> Outgoing {
        let sentVersion = item.updatedAt
        return Outgoing(mutation: mutation) { [context] result in
            switch result.status {
            case .applied:
                if item.pendingDelete {
                    context.delete(item)
                } else if item.updatedAt == sentVersion {
                    item.isDirty = false
                    item.syncError = nil
                }
            case .stale:
                // The server's newer version arrives with the pull that follows.
                item.isDirty = false
            case .gone:
                context.delete(item)
            case .forbidden, .invalid:
                if item.pendingDelete {
                    context.delete(item)
                } else {
                    item.isDirty = false
                    item.syncError = result.message ?? result.status.rawValue
                }
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
            for change in page.changes { apply(change, to: &records) }
            try context.save()
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
    /// the page is found or missed by the changes after it.
    private func apply(_ change: SyncChange, to records: inout PageRecords) {
        switch change.record {
        case .project(let record)?:
            if let local = records.projects[change.id] {
                if !keepsLocal(local, over: record.updatedAt) { local.apply(record) }
            } else {
                let item = ProjectItem(record, dirty: false)
                context.insert(item)
                records.projects[change.id] = item
            }
        case .section(let record)?:
            if let local = records.sections[change.id] {
                if !keepsLocal(local, over: record.updatedAt) { local.apply(record) }
            } else {
                let item = SectionItem(record, dirty: false)
                context.insert(item)
                records.sections[change.id] = item
            }
        case .task(let record)?:
            if let local = records.tasks[change.id] {
                if !keepsLocal(local, over: record.updatedAt) { local.apply(record) }
            } else {
                let item = TaskItem(record, dirty: false)
                context.insert(item)
                records.tasks[change.id] = item
            }
        case .reminder(let record)?:
            if let local = records.reminders[change.id] {
                if !keepsLocal(local, over: record.updatedAt) { local.apply(record) }
            } else {
                let item = ReminderItem(record, dirty: false)
                context.insert(item)
                records.reminders[change.id] = item
            }
        case .place(let record)?:
            if let local = records.places[change.id] {
                if !keepsLocal(local, over: record.updatedAt) { local.apply(record) }
            } else {
                let item = PlaceItem(record, dirty: false)
                context.insert(item)
                records.places[change.id] = item
            }
        case .comment?:
            break // Comments are shown from the API when a task opens; not stored yet.
        case nil:
            switch change.entity {
            case .project: if let local = records.projects.removeValue(forKey: change.id) { context.delete(local) }
            case .section: if let local = records.sections.removeValue(forKey: change.id) { context.delete(local) }
            case .task: if let local = records.tasks.removeValue(forKey: change.id) { context.delete(local) }
            case .reminder: if let local = records.reminders.removeValue(forKey: change.id) { context.delete(local) }
            case .place: if let local = records.places.removeValue(forKey: change.id) { context.delete(local) }
            case .comment: break
            }
        }
    }

    /// A local edit newer than the server's version wins; it goes out on the next push.
    private func keepsLocal(_ item: some SyncedItem, over serverVersion: Int64) -> Bool {
        item.isDirty && item.updatedAt > serverVersion
    }
}

/// `Store` asks the engine to send edits soon and tells it that the data changed.
extension SyncEngine: SyncScheduling {}
