import SwiftData
import SwiftUI
import ZimamKit

// MARK: Due date and time

/// «الموعد»: the day, the start day of a task that spans days, and the time in the day (all
/// day, a clock time, or a prayer, `TaskTimeRows`). The reminders follow in their own section,
/// and most count from this time.
struct TaskDueSection: View {
    @Environment(\.dateFormatterZimam) private var formatter

    let task: TaskItem
    let store: Store

    /// Clearing the due day clears the start day with it (`Store.setDueDate`).
    private var hasDate: Binding<Bool> {
        Binding(
            get: { task.dueDate != nil },
            set: { on in
                let today = formatter.dayString(from: Date())
                store.setDueDate(task, on ? today : nil)
            }
        )
    }

    /// A task that spans days is due after its start day.
    private var dueRange: PartialRangeFrom<Date> {
        let earliest = task.startDate.flatMap { DayMath.adding(1, to: $0) }.flatMap { formatter.date(fromDay: $0) }
        return (earliest ?? .distantPast)...
    }

    var body: some View {
        let dueDate = task.dueDate.flatMap { formatter.date(fromDay: $0) }
        Section("الموعد") {
            Toggle("تاريخ الاستحقاق", isOn: hasDate)
            if let dueDate {
                DatePicker("التاريخ", selection: dateBinding(dueDate), in: dueRange, displayedComponents: .date)
                Text(formatter.dual(dueDate, withYear: true))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                TaskStartDateRows(task: task, store: store)
            }
            TaskTimeRows(mode: task.timeMode, day: task.dueDate) { mode in
                store.setTime(task, mode, today: formatter.dayString(from: Date()))
            }
        }
    }

    private func dateBinding(_ current: Date) -> Binding<Date> {
        Binding(
            get: { current },
            set: { picked in store.setDueDate(task, formatter.dayString(from: picked)) }
        )
    }
}

/// «تاريخ البداية»: a task that spans days, from its start day to its due day. The start can only
/// be before the due day (the picker stops the day before it), as the server requires.
private struct TaskStartDateRows: View {
    @Environment(\.dateFormatterZimam) private var formatter

    let task: TaskItem
    let store: Store

    /// The day before the due day: the latest start of a task that spans days.
    private var latest: Date? {
        task.dueDate.flatMap { DayMath.adding(-1, to: $0) }.flatMap { formatter.date(fromDay: $0) }
    }

    /// On, the task starts the day before it is due; the user then picks the day.
    private var hasStart: Binding<Bool> {
        Binding(
            get: { task.startDate != nil },
            set: { on in
                _ = store.setStartDate(task, on ? task.dueDate.flatMap { DayMath.adding(-1, to: $0) } : nil)
            }
        )
    }

    var body: some View {
        Toggle("تاريخ البداية", isOn: hasStart)
        if let start = task.startDate.flatMap({ formatter.date(fromDay: $0) }), let latest {
            DatePicker("البداية", selection: startBinding(start), in: ...latest, displayedComponents: .date)
            Text(formatter.dual(start, withYear: true))
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            if let span = task.span {
                Text("تمتد المهمة \(ArabicCount.days(span.dayCount, locale: formatter.locale)).")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
    }

    private func startBinding(_ current: Date) -> Binding<Date> {
        Binding(
            get: { current },
            set: { picked in _ = store.setStartDate(task, formatter.dayString(from: picked)) }
        )
    }
}
