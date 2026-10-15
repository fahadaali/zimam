import CoreTransferable
import Foundation

/// A task being dragged, on the kanban board or to another day in the calendar. It carries
/// only the task's id, as text with a prefix, so no custom file type has to be declared; text
/// dragged in from elsewhere is refused (a bare UUID is accepted too).
struct TaskDragItem: Transferable, Sendable {
    let id: UUID

    private static let prefix = "zimam-task:"

    struct NotATaskError: Error {}

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (item: TaskDragItem) in
            TaskDragItem.prefix + item.id.uuidString
        }, importing: { (text: String) in
            let raw = text.hasPrefix(TaskDragItem.prefix) ? String(text.dropFirst(TaskDragItem.prefix.count)) : text
            guard let id = UUID(uuidString: raw) else { throw NotATaskError() }
            return TaskDragItem(id: id)
        })
    }
}
