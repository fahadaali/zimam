import Foundation
import SwiftData
import ZimamKit

extension Store {
    /// Adds imported projects, tasks and time reminders in one save, each marked for sync, then
    /// asks for a sync as any edit does. The sync engine sends projects before the tasks in them.
    func insertImported(projects: [ProjectRecord], tasks: [TaskRecord], reminders: [ReminderRecord]) throws {
        for project in projects { context.insert(ProjectItem(project, dirty: true)) }
        for task in tasks { context.insert(TaskItem(task, dirty: true)) }
        for reminder in reminders { context.insert(ReminderItem(reminder, dirty: true)) }
        try context.save()
        if let sync {
            sync.scheduleSync()
            sync.noteLocalChange()
        } else {
            ZimamShared.reloadWidgets()
        }
    }
}
