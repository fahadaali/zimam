import Foundation
import SwiftData
import ZimamKit

extension Store {
    /// Adds imported projects, tasks and time reminders in one save, each marked for sync, then
    /// asks for a sync as any edit does. The sync engine sends projects before the tasks in them.
    /// If the save fails, what this call inserted is taken out of the context again: the caller
    /// does not remember the import, so a retry would otherwise add it a second time, once a later
    /// save wrote both copies.
    func insertImported(projects: [ProjectRecord], tasks: [TaskRecord], reminders: [ReminderRecord]) throws {
        let projectItems = projects.map { ProjectItem($0, dirty: true) }
        let taskItems = tasks.map { TaskItem($0, dirty: true) }
        let reminderItems = reminders.map { ReminderItem($0, dirty: true) }
        for item in projectItems { context.insert(item) }
        for item in taskItems { context.insert(item) }
        for item in reminderItems { context.insert(item) }
        do {
            try context.save()
        } catch {
            for item in reminderItems { context.delete(item) }
            for item in taskItems { context.delete(item) }
            for item in projectItems { context.delete(item) }
            throw error
        }
        if let sync {
            sync.scheduleSync()
            sync.noteLocalChange()
        } else {
            ZimamShared.reloadTaskWidgets()
        }
    }
}
