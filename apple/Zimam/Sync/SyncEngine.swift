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
        get { Int64(ZimamShared.defaults.integer(forKey: Self.cursorKey)) }
        set { ZimamShared.defaults.set(Int(newValue), forKey: Self.cursorKey) }
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

        // Creations and edits first, parents before children; deletions last.
        var upserts: [Outgoing] = []
        var deletes: [Outgoing] = []
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
            for change in page.changes { apply(change) }
            try context.save()
            cursor = page.cursor
            hasMore = page.hasMore
        }
    }

    private func apply(_ change: SyncChange) {
        switch change.record {
        case .project(let record)?:
            if let local = fetch(ProjectItem.self, change.id) {
                if !keepsLocal(local, over: record.updatedAt) { local.apply(record) }
            } else {
                context.insert(ProjectItem(record, dirty: false))
            }
        case .section(let record)?:
            if let local = fetch(SectionItem.self, change.id) {
                if !keepsLocal(local, over: record.updatedAt) { local.apply(record) }
            } else {
                context.insert(SectionItem(record, dirty: false))
            }
        case .task(let record)?:
            if let local = fetch(TaskItem.self, change.id) {
                if !keepsLocal(local, over: record.updatedAt) { local.apply(record) }
            } else {
                context.insert(TaskItem(record, dirty: false))
            }
        case .reminder(let record)?:
            if let local = fetch(ReminderItem.self, change.id) {
                if !keepsLocal(local, over: record.updatedAt) { local.apply(record) }
            } else {
                context.insert(ReminderItem(record, dirty: false))
            }
        case .comment?:
            break // Comments are shown from the API when a task opens; not stored yet.
        case nil:
            switch change.entity {
            case .project: if let local = fetch(ProjectItem.self, change.id) { context.delete(local) }
            case .section: if let local = fetch(SectionItem.self, change.id) { context.delete(local) }
            case .task: if let local = fetch(TaskItem.self, change.id) { context.delete(local) }
            case .reminder: if let local = fetch(ReminderItem.self, change.id) { context.delete(local) }
            case .comment: break
            }
        }
    }

    /// A local edit newer than the server's version wins; it goes out on the next push.
    private func keepsLocal(_ item: some SyncedItem, over serverVersion: Int64) -> Bool {
        item.isDirty && item.updatedAt > serverVersion
    }

    private func fetch(_: ProjectItem.Type, _ id: UUID) -> ProjectItem? {
        var descriptor = FetchDescriptor<ProjectItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetch(_: SectionItem.Type, _ id: UUID) -> SectionItem? {
        var descriptor = FetchDescriptor<SectionItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetch(_: TaskItem.Type, _ id: UUID) -> TaskItem? {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetch(_: ReminderItem.Type, _ id: UUID) -> ReminderItem? {
        var descriptor = FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// `Store` asks the engine to send edits soon and tells it that the data changed.
extension SyncEngine: SyncScheduling {}
