import Foundation
import SwiftData
import ZimamKit

/// Sections (the kanban columns of a project), the order of tasks inside them, and the
/// project's list/board choice. Like every edit, these go through `Store` so they sync.
extension Store {
    // MARK: Sections

    /// The project's live sections in board order.
    func sections(in projectId: UUID) -> [SectionItem] {
        let descriptor = FetchDescriptor<SectionItem>(
            predicate: #Predicate { $0.projectId == projectId && !$0.pendingDelete },
            sortBy: [SortDescriptor(\SectionItem.sortOrder), SortDescriptor(\SectionItem.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Adds a section after the project's last one.
    @discardableResult
    func addSection(named name: String, to projectId: UUID) -> SectionItem? {
        let trimmed = ServerText.clip(name.trimmingCharacters(in: .whitespacesAndNewlines), to: ServerText.maxSectionName)
        guard !trimmed.isEmpty else { return nil }
        let order = ManualOrder.after(sections(in: projectId).map(\.sortOrder))
        let section = SectionItem(SectionRecord(projectId: projectId, name: trimmed, sortOrder: order), dirty: true)
        context.insert(section)
        commit()
        return section
    }

    func rename(_ section: SectionItem, to name: String) {
        let trimmed = ServerText.clip(name.trimmingCharacters(in: .whitespacesAndNewlines), to: ServerText.maxSectionName)
        guard !trimmed.isEmpty, trimmed != section.name else { return }
        section.name = trimmed
        touch(section)
    }

    /// Deletes a section. Its tasks stay in the project with no section: the server clears them
    /// with the deletion and sends them back. Until then those the server has in it keep it, and
    /// show under «بلا قسم» as the section is hidden, so a deletion the server turns down leaves
    /// them where they were; the sync engine clears it once the section is gone. An edit not sent
    /// yet leaves the section at once, as that section may never have reached the server.
    func delete(_ section: SectionItem) {
        let id: UUID? = section.id
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.sectionId == id }))) ?? []
        for task in tasks where task.isDirty {
            task.sectionId = nil
        }
        section.pendingDelete = true
        touch(section)
    }

    /// Moves a section one place earlier (-1) or later (+1) on the board.
    func moveSection(_ section: SectionItem, by offset: Int) {
        let list = sections(in: section.projectId)
        guard let from = list.firstIndex(where: { $0.id == section.id }) else { return }
        let to = from + offset
        guard to >= 0, to < list.count, to != from else { return }
        let orders = ManualOrder.moving(from: from, to: to, in: list.map(\.sortOrder))
        var ordered = list
        ordered.remove(at: from)
        ordered.insert(section, at: to)
        for (item, order) in zip(ordered, orders) where item.sortOrder != order {
            item.sortOrder = order
            markEdited(item)
        }
        commit()
    }

    // MARK: Tasks on the board

    /// Puts a task in a column (`sectionId` nil is «بلا قسم») at `index`, counted among
    /// `column` without the task itself. `column` is the destination as the board shows it.
    /// Usually only the task changes; a column never ordered by hand is renumbered once.
    func place(_ task: TaskItem, inSection sectionId: UUID?, at index: Int, column: [TaskItem]) {
        let others = column.filter { $0.id != task.id }
        let position = min(max(index, 0), others.count)
        let orders = ManualOrder.inserting(at: position, into: others.map(\.sortOrder))
        var ordered = others
        ordered.insert(task, at: position)
        let changedSection = task.sectionId != sectionId
        task.sectionId = sectionId
        for (item, order) in zip(ordered, orders) where item.sortOrder != order || (item.id == task.id && changedSection) {
            item.sortOrder = order
            markEdited(item)
        }
        commit()
    }

    /// Adds a task at the bottom of a column.
    @discardableResult
    func addTask(title: String, projectId: UUID, sectionId: UUID?, below column: [TaskItem]) -> TaskItem? {
        let trimmed = Self.taskTitle(title)
        guard !trimmed.isEmpty else { return nil }
        let record = TaskRecord(projectId: projectId, sectionId: sectionId, title: trimmed,
                                sortOrder: ManualOrder.after(column.map(\.sortOrder)))
        let task = TaskItem(record, dirty: true)
        context.insert(task)
        commit()
        return task
    }

    // MARK: Project layout

    /// The project's list or board choice. It is the project's `view` on the server,
    /// so the choice follows the project to the user's other devices.
    func setLayout(_ project: ProjectItem, _ layout: ProjectRecord.Layout) {
        guard project.layoutRaw != layout.rawValue else { return }
        project.layoutRaw = layout.rawValue
        touch(project)
    }

    /// Marks an edit without saving, for a batch saved once with `commit()`.
    private func markEdited(_ item: some SyncedItem) {
        item.updatedAt = nextUpdatedAt(after: item.updatedAt)
        item.isDirty = true
    }
}
