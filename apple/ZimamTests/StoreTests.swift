import Foundation
import SwiftData
import Testing
import ZimamKit
@testable import Zimam

/// `Store` on an in-memory store with the app's models (`zimamModelTypes`, as
/// `ZimamStore.makeContainer()` builds its schema) and no sync engine, as in the widget extension.
/// Swift Testing makes a new suite value, so a new empty store, for every test.
@MainActor
struct StoreTests {
    let container: ModelContainer
    let store: Store

    init() throws {
        let schema = Schema(zimamModelTypes)
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        store = Store(context: ModelContext(container), sync: nil)
    }

    // MARK: isAnchored (Store+Schedule.swift)

    @Test func aBareDatedTaskIsNotAnchored() {
        let task = store.addTask(title: "كتابة التقرير", dueDate: "2026-10-20")
        #expect(!store.isAnchored(task))
    }

    @Test func aReminderAnchorsTheTask() {
        let task = store.addTask(title: "كتابة التقرير", dueDate: "2026-10-20")
        let reminder = store.addTimeReminder(to: task.id, at: Date())
        #expect(store.isAnchored(task))

        // A reminder waiting to be deleted no longer counts.
        store.deleteReminder(reminder)
        #expect(!store.isAnchored(task))
    }

    @Test func aReminderOnAnotherTaskDoesNotAnchor() {
        let task = store.addTask(title: "كتابة التقرير", dueDate: "2026-10-20")
        let other = store.addTask(title: "مراجعة التقرير", dueDate: "2026-10-20")
        store.addPrayerReminder(to: other.id, prayer: .asr, offsetMinutes: 0)
        #expect(!store.isAnchored(task))
        #expect(store.isAnchored(other))
    }

    // MARK: move(_:toProject:section:) (Store+Move.swift)

    @Test func moveTakesTheSubtasksAndSetsTheSection() throws {
        let project = store.addProject(name: "البيت")
        let section = try #require(store.addSection(named: "قيد العمل", to: project.id))
        let task = store.addTask(title: "ترتيب المكتب")
        let child = try #require(store.addSubtask(to: task, title: "الأدراج"))
        let grandchild = try #require(store.addSubtask(to: child, title: "الدرج الأول"))
        task.assigneeId = UUID()

        // A version ahead of the clock, so each `touch` adds exactly 1 (`nextUpdatedAt`).
        let version = Milliseconds.now + 3_600_000
        task.updatedAt = version

        store.move(task, toProject: project.id, section: section.id)

        #expect(task.projectId == project.id)
        #expect(task.sectionId == section.id)
        #expect(task.assigneeId == nil)
        #expect(task.isDirty)
        // One version bump for the project and the section together.
        #expect(task.updatedAt == version + 1)

        // Subtasks follow to the project, without a section of their own.
        #expect(child.projectId == project.id)
        #expect(child.sectionId == nil)
        #expect(grandchild.projectId == project.id)
        #expect(grandchild.sectionId == nil)
    }

    @Test func moveToWhereTheTaskIsChangesNothing() throws {
        let project = store.addProject(name: "البيت")
        let section = try #require(store.addSection(named: "قيد العمل", to: project.id))
        let task = store.addTask(title: "ترتيب المكتب", projectId: project.id)
        store.move(task, toProject: project.id, section: section.id)

        let version = task.updatedAt
        store.move(task, toProject: project.id, section: section.id)
        #expect(task.updatedAt == version)
    }

    @Test func moveWithinTheProjectOnlyChangesTheSection() throws {
        let project = store.addProject(name: "البيت")
        let section = try #require(store.addSection(named: "قيد العمل", to: project.id))
        let task = store.addTask(title: "ترتيب المكتب", projectId: project.id)
        let assignee = UUID()
        task.assigneeId = assignee
        let version = Milliseconds.now + 3_600_000
        task.updatedAt = version

        store.move(task, toProject: project.id, section: section.id)

        #expect(task.projectId == project.id)
        #expect(task.sectionId == section.id)
        // The project did not change, so the assignee is still a member.
        #expect(task.assigneeId == assignee)
        #expect(task.updatedAt == version + 1)
    }

    // MARK: sections(in:) (Store+Board.swift)

    @Test func sectionsAreTheProjectsLiveOnesInBoardOrder() throws {
        let project = store.addProject(name: "العمل")
        let other = store.addProject(name: "البيت")
        let first = try #require(store.addSection(named: "للعمل", to: project.id))
        let second = try #require(store.addSection(named: "قيد العمل", to: project.id))
        let removed = try #require(store.addSection(named: "منجز", to: project.id))
        let elsewhere = try #require(store.addSection(named: "للشراء", to: other.id))

        store.delete(removed)
        #expect(store.sections(in: project.id).map(\.id) == [first.id, second.id])

        store.moveSection(second, by: -1)
        #expect(store.sections(in: project.id).map(\.id) == [second.id, first.id])

        #expect(store.sections(in: other.id).map(\.id) == [elsewhere.id])
        #expect(store.sections(in: UUID()).isEmpty)
    }

    // MARK: delete (Store.swift)

    @Test func deleteMarksTheTaskAndItsSubtasks() throws {
        let task = store.addTask(title: "السفر")
        let child = try #require(store.addSubtask(to: task, title: "الحجز"))
        let grandchild = try #require(store.addSubtask(to: child, title: "الفندق"))
        let other = store.addTask(title: "شراء الهدايا")

        store.delete(task)

        #expect(task.pendingDelete)
        #expect(task.isDirty)
        #expect(child.pendingDelete)
        #expect(grandchild.pendingDelete)
        // The parent's deletion covers the subtasks on the server, so they are not sent.
        #expect(!child.isDirty)
        #expect(!grandchild.isDirty)
        #expect(!other.pendingDelete)
    }
}
