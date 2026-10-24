import Foundation
import SwiftData
import Testing
import ZimamKit
@testable import Zimam

/// `SyncEngine` (Zimam/Sync/SyncEngine.swift) on an in-memory store, against `StubURLProtocol`.
/// Push (`POST /v1/sync`) and pull (`GET /v1/sync`) share a path, so the answers are registered per
/// method. Serialized because the tests share that path and the engine's keys in
/// `ZimamShared.defaults`, which each test clears and puts back (`SavedSyncDefaults`).
@MainActor
@Suite(.serialized)
struct SyncEngineTests {
    private static let path = "/v1/sync"

    let container: ModelContainer
    let context: ModelContext
    let engine: SyncEngine

    init() throws {
        let schema = Schema(zimamModelTypes)
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        let api = APIClient(baseURL: URL(string: "https://zimam.test")!, session: StubURLProtocol.session(), token: { "token" })
        engine = SyncEngine(api: api, context: context)
    }

    // MARK: Pull

    /// The second page brings a newer version of the task the first page created: it updates that
    /// task, and the next page is asked from the first page's cursor.
    @Test func pullAppliesEachPageWithoutDuplicates() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let id = UUID()
        try StubURLProtocol.respond(to: Self.path, method: "GET",
                                    with: page([upsert(TaskRecord(id: id, title: "مراجعة العقد", updatedAt: 1_000))],
                                               cursor: 1, hasMore: true))
        try StubURLProtocol.respond(to: Self.path, method: "GET",
                                    with: page([upsert(TaskRecord(id: id, title: "مراجعة العقد مع الإدارة", updatedAt: 2_000))],
                                               cursor: 2))
        StubURLProtocol.release(Self.path)

        await engine.sync()

        let tasks = try allTasks()
        #expect(tasks.count == 1)
        #expect(tasks.first?.id == id)
        #expect(tasks.first?.title == "مراجعة العقد مع الإدارة")
        #expect(tasks.first?.updatedAt == 2_000)
        #expect(tasks.first?.isDirty == false)
        #expect(cursor == 2)
        #expect(engine.lastError == nil)
        // Nothing was dirty, so nothing was pushed.
        #expect(StubURLProtocol.requestCount(for: Self.path, method: "POST") == 0)
        let asked = StubURLProtocol.recordedRequests(to: Self.path, method: "GET").map { cursorQuery($0) }
        #expect(asked == ["0", "1"])
    }

    /// A record created and deleted within one page is never stored, and a delete removes a record
    /// that was already here.
    @Test func upsertThenDeleteInOnePageLeavesNoRecord() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let existing = try insertTask(TaskRecord(title: "شراء الهدايا", updatedAt: 500), dirty: false)
        let id = UUID()
        try StubURLProtocol.respond(to: Self.path, method: "GET",
                                    with: page([upsert(TaskRecord(id: id, title: "مراجعة العقد", updatedAt: 1_000)),
                                                delete(id), delete(existing.id)],
                                               cursor: 3))
        StubURLProtocol.release(Self.path)

        await engine.sync()

        #expect(try allTasks().isEmpty)
        #expect(cursor == 3)
        #expect(engine.lastError == nil)
    }

    /// An edit made while the push is in flight stays dirty, and the pull that follows does not
    /// overwrite it with the server's older version (`keepsLocal`).
    @Test func aLocalEditNewerThanTheServersIsKept() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let id = UUID()
        let task = try insertTask(TaskRecord(id: id, title: "مراجعة العقد", updatedAt: 5_000), dirty: true)
        StubURLProtocol.respond(to: Self.path, method: "POST", with: results([id], status: "applied"))
        try StubURLProtocol.respond(to: Self.path, method: "GET",
                                    with: page([upsert(TaskRecord(id: id, title: "مراجعة العقد مع المحامي", updatedAt: 5_500))],
                                               cursor: 4))

        let engine = self.engine
        let run = Task { await engine.sync() }
        try await StubURLProtocol.waitForRequest(to: Self.path, method: "POST")
        task.title = "مراجعة العقد مع الإدارة"
        task.updatedAt = 6_000
        try context.save()
        StubURLProtocol.release(Self.path)
        await run.value

        let tasks = try allTasks()
        #expect(tasks.count == 1)
        #expect(task.title == "مراجعة العقد مع الإدارة")
        #expect(task.updatedAt == 6_000)
        // Applied at the version sent (5000), not the one edited since, so it goes out next time.
        #expect(task.isDirty)
        #expect(cursor == 4)
        #expect(engine.lastError == nil)
    }

    // MARK: Push

    @Test func pushSendsTheDirtyTaskAndSettlesItsResult() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let id = UUID()
        let task = try insertTask(TaskRecord(id: id, title: "مراجعة العقد", updatedAt: 5_000), dirty: true)
        StubURLProtocol.respond(to: Self.path, method: "POST", with: results([id], status: "applied"))
        StubURLProtocol.respond(to: Self.path, method: "GET", with: page([], cursor: 5))
        StubURLProtocol.release(Self.path)

        await engine.sync()

        #expect(!task.isDirty)
        #expect(task.syncError == nil)
        #expect(cursor == 5)
        #expect(engine.lastError == nil)

        let pushes = StubURLProtocol.recordedRequests(to: Self.path, method: "POST")
        #expect(pushes.count == 1)
        let body = try #require(pushes.first?.body)
        let object = try JSONSerialization.jsonObject(with: body)
        let json = try #require(object as? [String: Any])
        let mutations = try #require(json["mutations"] as? [[String: Any]])
        #expect(mutations.count == 1)
        #expect((mutations.first?["op"] as? String) == "upsert")
        #expect((mutations.first?["entity"] as? String) == "task")
        let data = try #require(mutations.first?["data"] as? [String: Any])
        #expect((data["id"] as? String).flatMap(UUID.init(uuidString:)) == id)
        #expect((data["updatedAt"] as? Int) == 5_000)
    }

    /// A sync asked for while one runs waits for it, and for the round it adds: the task created
    /// meanwhile is on the server when the call returns, so a request made next finds it.
    @Test func aSyncAskedForDuringAnotherReturnsOnceItsEditsAreSent() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let first = try insertTask(TaskRecord(title: "مراجعة العقد", updatedAt: 5_000), dirty: true)
        StubURLProtocol.respond(to: Self.path, method: "POST", with: results([first.id], status: "applied"))
        StubURLProtocol.respond(to: Self.path, method: "GET", with: page([], cursor: 5))

        let engine = self.engine
        let running = Task { await engine.sync() }
        try await StubURLProtocol.waitForRequest(to: Self.path, method: "POST")
        let second = try insertTask(TaskRecord(title: "إرسال العقد", updatedAt: 6_000), dirty: true)
        StubURLProtocol.respond(to: Self.path, method: "POST", with: results([second.id], status: "applied"))
        let joined = Task { await engine.sync() }
        // Lets it start, and find the sync running, before the first push is answered.
        await Task.yield()
        StubURLProtocol.release(Self.path)
        await joined.value

        #expect(!second.isDirty)
        #expect(StubURLProtocol.requestCount(for: Self.path, method: "POST") == 2)
        await running.value
        #expect(!first.isDirty)
        #expect(engine.lastError == nil)
    }

    /// An edit made while a `stale` answer is on its way stays dirty, and the pull that follows
    /// does not overwrite it with the server's older version.
    @Test func anEditMadeDuringAStaleAnswerIsKept() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let id = UUID()
        let task = try insertTask(TaskRecord(id: id, title: "مراجعة العقد", updatedAt: 5_000), dirty: true)
        StubURLProtocol.respond(to: Self.path, method: "POST", with: results([id], status: "stale"))
        try StubURLProtocol.respond(to: Self.path, method: "GET",
                                    with: page([upsert(TaskRecord(id: id, title: "مراجعة العقد مع المحامي", updatedAt: 5_500))],
                                               cursor: 4))

        let engine = self.engine
        let run = Task { await engine.sync() }
        try await StubURLProtocol.waitForRequest(to: Self.path, method: "POST")
        task.title = "مراجعة العقد مع الإدارة"
        task.updatedAt = 6_000
        try context.save()
        StubURLProtocol.release(Self.path)
        await run.value

        #expect(task.title == "مراجعة العقد مع الإدارة")
        #expect(task.isDirty)
    }

    /// A task deleted while its edit is in flight: the edit's `applied` does not remove it here,
    /// since its deletion was never sent. It stays hidden and dirty, the echo of the edit does not
    /// bring it back, and the next sync sends the deletion.
    @Test func aTaskDeletedWhileItsEditIsInFlightIsStillDeleted() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let id = UUID()
        let task = try insertTask(TaskRecord(id: id, title: "مراجعة العقد", updatedAt: 5_000), dirty: true)
        StubURLProtocol.respond(to: Self.path, method: "POST", with: results([id], status: "applied"))
        // The echo of the edit, then the deletion once it reached the server.
        try StubURLProtocol.respond(to: Self.path, method: "GET",
                                    with: page([upsert(TaskRecord(id: id, title: "مراجعة العقد", updatedAt: 5_000))], cursor: 4))
        StubURLProtocol.respond(to: Self.path, method: "GET", with: page([delete(id)], cursor: 5))

        let engine = self.engine
        let run = Task { await engine.sync() }
        try await StubURLProtocol.waitForRequest(to: Self.path, method: "POST")
        Store(context: context, sync: nil).delete(task)
        StubURLProtocol.release(Self.path)
        await run.value

        #expect(try allTasks().count == 1)
        #expect(task.pendingDelete)
        #expect(task.isDirty)

        await engine.sync()

        #expect(try allTasks().isEmpty)
        let pushes = StubURLProtocol.recordedRequests(to: Self.path, method: "POST")
        #expect(pushes.count == 2)
        let body = try #require(pushes.last?.body)
        let object = try JSONSerialization.jsonObject(with: body)
        let json = try #require(object as? [String: Any])
        let mutations = try #require(json["mutations"] as? [[String: Any]])
        #expect((mutations.first?["op"] as? String) == "delete")
    }

    /// Another device edited the task after it was deleted here: the server answers `stale` and
    /// keeps it, so the later edit wins. The task shows again, with the subtask and the reminder
    /// its deletion hid, and takes the server's version from the pull.
    @Test func aStaleDeleteShowsTheTaskAndWhatItHidAgain() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let (task, child, reminder) = try insertTree()
        Store(context: context, sync: nil).delete(task)
        #expect(child.pendingDelete && reminder.pendingDelete)
        StubURLProtocol.respond(to: Self.path, method: "POST", with: results([task.id], status: "stale"))
        try StubURLProtocol.respond(to: Self.path, method: "GET",
                                    with: page([upsert(TaskRecord(id: task.id, title: "السفر إلى جدة",
                                                                  updatedAt: Milliseconds.now + 60_000))], cursor: 6))
        StubURLProtocol.release(Self.path)

        await engine.sync()

        #expect(!task.pendingDelete)
        #expect(!task.isDirty)
        #expect(task.title == "السفر إلى جدة")
        #expect(!child.pendingDelete)
        #expect(!reminder.pendingDelete)
    }

    /// A deletion the server refuses (a viewer's, in a shared project) leaves the task where it is,
    /// here as there, with what its deletion hid, and the reason kept on it.
    @Test func aForbiddenDeleteKeepsTheTaskAndWhatItHid() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let (task, child, reminder) = try insertTree()
        Store(context: context, sync: nil).delete(task)
        StubURLProtocol.respond(to: Self.path, method: "POST", with: results([task.id], status: "forbidden"))
        StubURLProtocol.respond(to: Self.path, method: "GET", with: page([], cursor: 6))
        StubURLProtocol.release(Self.path)

        await engine.sync()

        #expect(try allTasks().count == 2)
        #expect(!task.pendingDelete)
        #expect(!task.isDirty)
        #expect(task.syncError != nil)
        #expect(!child.pendingDelete)
        #expect(!reminder.pendingDelete)
    }

    // MARK: Reset

    /// Signing out while a pull is in flight: the page that arrives afterwards belongs to the
    /// previous account, so none of it is applied, and the cursor stays at zero.
    @Test func resetDuringAPullAppliesNothingOfItsPage() async throws {
        let saved = prepare()
        defer { saved.restore() }
        ZimamShared.defaults.set(7, forKey: "sync.cursor")
        try insertTask(TaskRecord(title: "شراء الهدايا", updatedAt: 500), dirty: false)
        try StubURLProtocol.respond(to: Self.path, method: "GET",
                                    with: page([upsert(TaskRecord(title: "مراجعة العقد", updatedAt: 1_000))], cursor: 8))

        let engine = self.engine
        let run = Task { await engine.sync() }
        try await StubURLProtocol.waitForRequest(to: Self.path, method: "GET")
        engine.reset()
        #expect(try allTasks().isEmpty)
        StubURLProtocol.release(Self.path)
        await run.value

        #expect(try allTasks().isEmpty)
        #expect(cursor == 0)
        #expect(!ZimamShared.defaults.bool(forKey: "sync.wipePending"))
        #expect(engine.lastSyncedAt == nil)
        #expect(engine.lastError == nil)
        // The superseded run stops; it does not pull again.
        #expect(StubURLProtocol.requestCount(for: Self.path, method: "GET") == 1)
    }

    /// Signing out while a push is in flight: its results are not settled on the wiped records,
    /// and the run stops before pulling.
    @Test func resetDuringAPushSettlesNothingAndDoesNotPull() async throws {
        let saved = prepare()
        defer { saved.restore() }
        let id = UUID()
        try insertTask(TaskRecord(id: id, title: "مراجعة العقد", updatedAt: 5_000), dirty: true)
        StubURLProtocol.respond(to: Self.path, method: "POST", with: results([id], status: "applied"))
        try StubURLProtocol.respond(to: Self.path, method: "GET",
                                    with: page([upsert(TaskRecord(title: "شراء الهدايا", updatedAt: 1_000))], cursor: 8))

        let engine = self.engine
        let run = Task { await engine.sync() }
        try await StubURLProtocol.waitForRequest(to: Self.path, method: "POST")
        engine.reset()
        StubURLProtocol.release(Self.path)
        await run.value

        #expect(try allTasks().isEmpty)
        #expect(cursor == 0)
        #expect(engine.lastSyncedAt == nil)
        #expect(engine.lastError == nil)
        #expect(StubURLProtocol.requestCount(for: Self.path, method: "POST") == 1)
        #expect(StubURLProtocol.requestCount(for: Self.path, method: "GET") == 0)
    }

    /// A wipe left pending (it failed at sign-out) runs before the next sync sends anything: the
    /// previous account's dirty task is never pushed, and the pull starts over from zero.
    @Test func aPendingWipeRunsBeforeAnythingIsSent() async throws {
        let saved = prepare()
        defer { saved.restore() }
        try insertTask(TaskRecord(title: "مراجعة العقد", updatedAt: 5_000), dirty: true)
        try insertTask(TaskRecord(title: "شراء الهدايا", updatedAt: 500), dirty: false)
        ZimamShared.defaults.set(9, forKey: "sync.cursor")
        ZimamShared.defaults.set(true, forKey: "sync.wipePending")
        StubURLProtocol.respond(to: Self.path, method: "GET", with: page([], cursor: 3))
        StubURLProtocol.release(Self.path)

        await engine.sync()

        #expect(try allTasks().isEmpty)
        #expect(StubURLProtocol.requestCount(for: Self.path, method: "POST") == 0)
        let asked = StubURLProtocol.recordedRequests(to: Self.path, method: "GET").map { cursorQuery($0) }
        #expect(asked == ["0"])
        #expect(cursor == 3)
        #expect(!ZimamShared.defaults.bool(forKey: "sync.wipePending"))
        #expect(engine.lastError == nil)
    }

    // MARK: Helpers

    /// The engine's cursor, as it keeps it.
    private var cursor: Int { ZimamShared.defaults.integer(forKey: "sync.cursor") }

    /// Forgets the stub's sync requests and answers, and clears the engine's keys. The caller puts
    /// the keys back with `restore()`.
    private func prepare() -> SavedSyncDefaults {
        StubURLProtocol.reset(Self.path)
        return SavedSyncDefaults()
    }

    @discardableResult
    private func insertTask(_ record: TaskRecord, dirty: Bool) throws -> TaskItem {
        let task = TaskItem(record, dirty: dirty)
        context.insert(task)
        try context.save()
        return task
    }

    private func allTasks() throws -> [TaskItem] {
        try context.fetch(FetchDescriptor<TaskItem>())
    }

    /// A synced task with a subtask, and a reminder on the subtask.
    private func insertTree() throws -> (TaskItem, TaskItem, ReminderItem) {
        let task = try insertTask(TaskRecord(title: "السفر", updatedAt: 1_000), dirty: false)
        let child = try insertTask(TaskRecord(parentId: task.id, title: "الحجز", updatedAt: 1_000), dirty: false)
        let reminder = ReminderItem(ReminderRecord(taskId: child.id, kind: .time, at: "2026-10-20T09:00:00+03:00", updatedAt: 1_000),
                                    dirty: false)
        context.insert(reminder)
        try context.save()
        return (task, child, reminder)
    }

    /// The `cursor` a pull asked from.
    private func cursorQuery(_ request: StubURLProtocol.Recorded) -> String? {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        return items?.first { $0.name == "cursor" }?.value
    }

    /// A change of `GET /v1/sync` that creates or updates a task, as the server sends it.
    private func upsert(_ task: TaskRecord) throws -> String {
        let data = try String(decoding: JSONEncoder().encode(task), as: UTF8.self)
        return #"{"entity":"task","id":"\#(task.id.uuidString.lowercased())","op":"upsert","data":\#(data)}"#
    }

    /// A change of `GET /v1/sync` that deletes a task.
    private func delete(_ id: UUID) -> String {
        #"{"entity":"task","id":"\#(id.uuidString.lowercased())","op":"delete"}"#
    }

    /// A page of `GET /v1/sync`.
    private func page(_ changes: [String], cursor: Int64, hasMore: Bool = false) -> Data {
        Data(#"{"changes":[\#(changes.joined(separator: ","))],"cursor":\#(cursor),"hasMore":\#(hasMore)}"#.utf8)
    }

    /// The answer of `POST /v1/sync`: one result per task, in order.
    private func results(_ ids: [UUID], status: String) -> Data {
        let items = ids.map { #"{"entity":"task","id":"\#($0.uuidString.lowercased())","status":"\#(status)"}"# }
        return Data(#"{"results":[\#(items.joined(separator: ","))]}"#.utf8)
    }
}

/// `SyncEngine`'s keys in `ZimamShared.defaults`. The tests share that suite with the host app (on
/// a signed Mac build, the App Group of the installed app), so each test starts without them and
/// puts back what was there: a cursor, or a pending wipe, left behind would reach the real app.
@MainActor
private struct SavedSyncDefaults {
    private static let keys = ["sync.cursor", "sync.wipePending"]
    private let values: [String: Any]

    init() {
        var values: [String: Any] = [:]
        for key in Self.keys {
            if let value = ZimamShared.defaults.object(forKey: key) { values[key] = value }
            ZimamShared.defaults.removeObject(forKey: key)
        }
        self.values = values
    }

    func restore() {
        for key in Self.keys {
            if let value = values[key] {
                ZimamShared.defaults.set(value, forKey: key)
            } else {
                ZimamShared.defaults.removeObject(forKey: key)
            }
        }
    }
}
