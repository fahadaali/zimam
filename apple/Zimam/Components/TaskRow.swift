import SwiftUI
import ZimamKit

/// The basic unit of every list. See design/components/TaskRow.
/// From the leading edge: the completion circle, the title with up to three
/// chips under it, then the priority flag at the trailing edge.
struct TaskRow: View {
    let task: TaskItem
    var projectName: String?
    /// The smaller title used on kanban cards (TaskRow `compact` in design/components).
    var compact = false
    let onToggle: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.prayerScheduleZimam) private var schedule

    var body: some View {
        HStack(alignment: .top, spacing: ZimamSpacing.space3) {
            CompletionCircle(isDone: task.isDone, alignment: .top, action: onToggle)

            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Text(task.title)
                    .font(compact ? ZimamType.callout : ZimamType.body)
                    .foregroundStyle(task.isDone ? ZimamColor.inkFaint : ZimamColor.ink)
                    .strikethrough(task.isDone)
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .lineLimit(1)
                }
                chips
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PriorityFlag(priority: task.priority)
                .padding(.top, ZimamSpacing.space2)
        }
        .padding(.vertical, ZimamSpacing.space1)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var chips: some View {
        let date = task.dueDate.flatMap(formatter.date(fromDay:))
        let mode = task.timeMode
        // A prayer's time on the task's day (today for one that repeats daily), as if typed in.
        let time = TaskTiming.shownTime(of: mode, dueDay: task.dueDate, schedule: schedule, formatter: formatter)
        if date != nil || !mode.isAllDay || projectName != nil {
            HStack(spacing: ZimamSpacing.space2) {
                if let date {
                    DateChip(text: formatter.label(for: date), overdue: !task.isDone && date < Calendar.current.startOfDay(for: Date()))
                }
                switch mode {
                case .allDay:
                    EmptyView()
                case .clock:
                    if let time { TimeChip(text: formatter.time(time)) }
                case .prayer(let prayer, let offset):
                    let phrase = PrayerPhrase.text(prayer, offsetMinutes: offset, locale: formatter.locale)
                    if let time {
                        PrayerChip(text: formatter.time(time), phrase: phrase)
                    } else {
                        PrayerChip(text: phrase)
                    }
                }
                if let projectName {
                    Text(projectName)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
        }
    }
}

private struct DateFormatterKey: EnvironmentKey {
    static let defaultValue = DualDateFormatter()
}

private struct PrayerScheduleKey: EnvironmentKey {
    static let defaultValue: PrayerSchedule? = nil
}

extension EnvironmentValues {
    /// The user's date formatter: their primary calendar first.
    var dateFormatterZimam: DualDateFormatter {
        get { self[DateFormatterKey.self] }
        set { self[DateFormatterKey.self] = newValue }
    }

    /// Prayer times for the saved place, to show a prayer-anchored task's time; nil before the
    /// first location, when the row shows the prayer phrase instead.
    var prayerScheduleZimam: PrayerSchedule? {
        get { self[PrayerScheduleKey.self] }
        set { self[PrayerScheduleKey.self] = newValue }
    }
}
