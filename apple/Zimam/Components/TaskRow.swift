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

    var body: some View {
        HStack(alignment: .top, spacing: ZimamSpacing.space3) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(ZimamType.title)
                    .foregroundStyle(task.isDone ? ZimamColor.brand : ZimamColor.lineStrong)
                    .frame(minWidth: ZimamSpacing.space11, minHeight: ZimamSpacing.space11, alignment: .top)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "إلغاء الإنجاز" : "إنجاز")

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
        if date != nil || task.duePrayer != nil || projectName != nil {
            HStack(spacing: ZimamSpacing.space2) {
                if let date {
                    DateChip(text: formatter.label(for: date), overdue: !task.isDone && date < Calendar.current.startOfDay(for: Date()))
                }
                if let prayer = task.duePrayer {
                    PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: task.duePrayerOffset, locale: formatter.locale))
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

extension EnvironmentValues {
    /// The user's date formatter: their primary calendar first.
    var dateFormatterZimam: DualDateFormatter {
        get { self[DateFormatterKey.self] }
        set { self[DateFormatterKey.self] = newValue }
    }
}
