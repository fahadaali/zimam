import Foundation
import SwiftData
import ZimamKit

/// Today's open top-level tasks, as the Today screen lists them: due today or overdue,
/// by date and time. Used by the widgets and by Siri.
enum TodayTasks {
    /// The API's day string for today, in the device's time zone.
    static func todayString(_ now: Date = Date()) -> String {
        DualDateFormatter().dayString(from: now)
    }

    static func fetch(in context: ModelContext, today: String) -> [TaskItem] {
        let all = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        return all
            .filter { task in
                guard task.parentId == nil, !task.isDone, let due = task.dueDate else { return false }
                return due <= today
            }
            .sorted { first, second in
                let a = (first.dueDate ?? "", first.dueTime ?? "", first.sortOrder)
                let b = (second.dueDate ?? "", second.dueTime ?? "", second.sortOrder)
                return a < b
            }
    }
}
