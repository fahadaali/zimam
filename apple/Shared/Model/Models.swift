import Foundation
import SwiftData
import ZimamKit

// Local copies of server records, so the app works offline. Records refer to
// each other by id (as the API does) rather than SwiftData relationships, which
// keeps applying sync changes simple in any order.
//
// `isDirty` marks an edit not yet sent; `pendingDelete` hides a record until
// its deletion reaches the server.

@Model
final class ProjectItem {
    @Attribute(.unique) var id: UUID
    var ownerId: UUID?
    var parentId: UUID?
    var kindRaw: String
    var name: String
    var layoutRaw: String
    var sortOrder: Double
    var archivedAt: Int64?
    var createdAt: Int64
    var updatedAt: Int64
    var isDirty: Bool
    var pendingDelete: Bool
    var syncError: String?

    init(_ r: ProjectRecord, dirty: Bool) {
        id = r.id
        ownerId = r.ownerId
        parentId = r.parentId
        kindRaw = r.kind.rawValue
        name = r.name
        layoutRaw = r.unknownView ?? r.view.rawValue
        sortOrder = r.sortOrder
        archivedAt = r.archivedAt
        createdAt = r.createdAt ?? r.updatedAt
        updatedAt = r.updatedAt
        isDirty = dirty
        pendingDelete = false
    }

    func apply(_ r: ProjectRecord) {
        ownerId = r.ownerId
        parentId = r.parentId
        kindRaw = r.kind.rawValue
        name = r.name
        layoutRaw = r.unknownView ?? r.view.rawValue
        sortOrder = r.sortOrder
        archivedAt = r.archivedAt
        if let created = r.createdAt { createdAt = created }
        updatedAt = r.updatedAt
        isDirty = false
        syncError = nil
    }

    /// A view this build does not know (`layoutRaw` keeps it as the server sent it) opens as a
    /// list and goes back unchanged, so another app's choice is not overwritten.
    var record: ProjectRecord {
        let layout = ProjectRecord.Layout(rawValue: layoutRaw)
        var record = ProjectRecord(id: id, ownerId: ownerId, parentId: parentId,
                                   kind: ProjectRecord.Kind(rawValue: kindRaw) ?? .project, name: name,
                                   view: layout ?? .list, sortOrder: sortOrder, archivedAt: archivedAt,
                                   createdAt: createdAt, updatedAt: updatedAt)
        record.unknownView = layout == nil ? layoutRaw : nil
        return record
    }
}

@Model
final class SectionItem {
    @Attribute(.unique) var id: UUID
    var projectId: UUID
    var name: String
    var sortOrder: Double
    var createdAt: Int64
    var updatedAt: Int64
    var isDirty: Bool
    var pendingDelete: Bool
    var syncError: String?

    init(_ r: SectionRecord, dirty: Bool) {
        id = r.id
        projectId = r.projectId
        name = r.name
        sortOrder = r.sortOrder
        createdAt = r.createdAt ?? r.updatedAt
        updatedAt = r.updatedAt
        isDirty = dirty
        pendingDelete = false
    }

    func apply(_ r: SectionRecord) {
        projectId = r.projectId
        name = r.name
        sortOrder = r.sortOrder
        if let created = r.createdAt { createdAt = created }
        updatedAt = r.updatedAt
        isDirty = false
        syncError = nil
    }

    var record: SectionRecord {
        SectionRecord(id: id, projectId: projectId, name: name, sortOrder: sortOrder, createdAt: createdAt, updatedAt: updatedAt)
    }
}

@Model
final class TaskItem {
    @Attribute(.unique) var id: UUID
    var ownerId: UUID?
    var projectId: UUID?
    var sectionId: UUID?
    var parentId: UUID?
    var title: String
    var notes: String?
    var statusRaw: String
    var priorityRaw: Int
    var tags: [String]
    var dueDate: String?
    /// The first day of a multi-day task (`TaskRecord.startDate`). Added after the first release:
    /// an optional attribute, so SwiftData migrates existing stores on its own.
    var startDate: String?
    var dueTime: String?
    var duePrayerRaw: String?
    var duePrayerOffset: Int?
    var recurrence: String?
    var assigneeId: UUID?
    var sortOrder: Double
    var completedAt: Int64?
    var createdAt: Int64
    var updatedAt: Int64
    var isDirty: Bool
    var pendingDelete: Bool
    var syncError: String?

    init(_ r: TaskRecord, dirty: Bool) {
        id = r.id
        ownerId = r.ownerId
        projectId = r.projectId
        sectionId = r.sectionId
        parentId = r.parentId
        title = r.title
        notes = r.notes
        statusRaw = r.status.rawValue
        priorityRaw = r.priority.rawValue
        tags = r.tags
        dueDate = r.dueDate
        startDate = r.startDate
        dueTime = r.dueTime
        duePrayerRaw = r.duePrayer?.rawValue
        duePrayerOffset = r.duePrayerOffset
        recurrence = r.recurrence
        assigneeId = r.assigneeId
        sortOrder = r.sortOrder
        completedAt = r.completedAt
        createdAt = r.createdAt ?? r.updatedAt
        updatedAt = r.updatedAt
        isDirty = dirty
        pendingDelete = false
    }

    func apply(_ r: TaskRecord) {
        ownerId = r.ownerId
        projectId = r.projectId
        sectionId = r.sectionId
        parentId = r.parentId
        title = r.title
        notes = r.notes
        statusRaw = r.status.rawValue
        priorityRaw = r.priority.rawValue
        tags = r.tags
        dueDate = r.dueDate
        startDate = r.startDate
        dueTime = r.dueTime
        duePrayerRaw = r.duePrayer?.rawValue
        duePrayerOffset = r.duePrayerOffset
        recurrence = r.recurrence
        assigneeId = r.assigneeId
        sortOrder = r.sortOrder
        completedAt = r.completedAt
        if let created = r.createdAt { createdAt = created }
        updatedAt = r.updatedAt
        isDirty = false
        syncError = nil
    }

    var record: TaskRecord {
        TaskRecord(id: id, ownerId: ownerId, projectId: projectId, sectionId: sectionId, parentId: parentId, title: title,
                   notes: notes, status: status, priority: priority, tags: tags, dueDate: dueDate, startDate: startDate, dueTime: dueTime,
                   duePrayer: duePrayer, duePrayerOffset: duePrayerOffset, recurrence: recurrence, assigneeId: assigneeId,
                   sortOrder: sortOrder, completedAt: completedAt, createdAt: createdAt, updatedAt: updatedAt)
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .todo }
        set { statusRaw = newValue.rawValue }
    }

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue }
    }

    var duePrayer: Prayer? {
        get { duePrayerRaw.flatMap(Prayer.init(rawValue:)) }
        set { duePrayerRaw = newValue?.rawValue }
    }

    var isDone: Bool { status == .done }

    /// The days the task occupies on the calendar and the timeline; nil without a due day.
    var span: DaySpan? { DaySpan(startDate: startDate, dueDate: dueDate) }
}

@Model
final class ReminderItem {
    @Attribute(.unique) var id: UUID
    var taskId: UUID
    var kindRaw: String
    var at: String?
    var prayerRaw: String?
    var offsetMinutes: Int?
    var locationJSON: Data?
    var createdAt: Int64
    var updatedAt: Int64
    var isDirty: Bool
    var pendingDelete: Bool
    var syncError: String?

    init(_ r: ReminderRecord, dirty: Bool) {
        id = r.id
        taskId = r.taskId
        kindRaw = r.kind.rawValue
        at = r.at
        prayerRaw = r.prayer?.rawValue
        offsetMinutes = r.offsetMinutes
        locationJSON = r.location.flatMap { try? JSONEncoder().encode($0) }
        createdAt = r.createdAt ?? r.updatedAt
        updatedAt = r.updatedAt
        isDirty = dirty
        pendingDelete = false
    }

    func apply(_ r: ReminderRecord) {
        taskId = r.taskId
        kindRaw = r.kind.rawValue
        at = r.at
        prayerRaw = r.prayer?.rawValue
        offsetMinutes = r.offsetMinutes
        locationJSON = r.location.flatMap { try? JSONEncoder().encode($0) }
        if let created = r.createdAt { createdAt = created }
        updatedAt = r.updatedAt
        isDirty = false
        syncError = nil
    }

    var record: ReminderRecord {
        ReminderRecord(id: id, taskId: taskId, kind: ReminderRecord.Kind(rawValue: kindRaw) ?? .time, at: at,
                       prayer: prayerRaw.flatMap(Prayer.init(rawValue:)), offsetMinutes: offsetMinutes,
                       location: locationJSON.flatMap { try? JSONDecoder().decode(ReminderRecord.Location.self, from: $0) },
                       createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// A local record that syncs with the API.
protocol SyncedItem: PersistentModel {
    var updatedAt: Int64 { get set }
    var isDirty: Bool { get set }
    var pendingDelete: Bool { get set }
    var syncError: String? { get set }
}

extension ProjectItem: SyncedItem {}
extension SectionItem: SyncedItem {}
extension TaskItem: SyncedItem {}
extension ReminderItem: SyncedItem {}

/// Every local model, for the container and for wiping data on sign-out.
let zimamModelTypes: [any PersistentModel.Type] = [ProjectItem.self, SectionItem.self, TaskItem.self, ReminderItem.self]

/// Marks a local edit: bumps `updatedAt` past the last known version so the newest edit wins.
func nextUpdatedAt(after current: Int64) -> Int64 {
    max(Milliseconds.now, current + 1)
}
