import Foundation
import SwiftData
import ZimamKit

/// Moving a task to another project or section: dropped on the sidebar (iPad, Mac) or chosen
/// with «نقل إلى مشروع…». Built on `move(_:toProject:)`, which takes the subtasks along and
/// clears the assignee when the project changes.
extension Store {
    /// Puts a top-level task in `projectId` (nil is the inbox) and in `sectionId` there (nil
    /// is the project without a section). A new section takes it at the bottom.
    func move(_ task: TaskItem, toProject projectId: UUID?, section sectionId: UUID?) {
        move(task, toProject: projectId)
        guard task.sectionId != sectionId else { return }
        if let sectionId {
            let id = task.id
            let all = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
            let column = all.filter { $0.sectionId == sectionId && $0.parentId == nil && $0.id != id }
            task.sortOrder = ManualOrder.after(column.map(\.sortOrder))
        }
        task.sectionId = sectionId
        touch(task)
    }
}
