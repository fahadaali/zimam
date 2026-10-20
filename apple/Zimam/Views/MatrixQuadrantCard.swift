import SwiftUI
import ZimamKit

/// A quadrant: its icon, name and count, then its tasks. Takes dropped tasks.
struct QuadrantCard: View {
    let quadrant: PriorityQuadrant
    let tasks: [TaskItem]
    let names: [UUID: String]
    let today: String
    let isTargeted: Bool
    let onToggle: (TaskItem) -> Void
    let onMove: (TaskItem, PriorityQuadrant) -> Void
    let onDrop: ([UUID]) -> Bool
    let onTargeted: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            QuadrantHeader(quadrant: quadrant, count: tasks.count)

            if tasks.isEmpty {
                Text("لا مهام هنا.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .frame(minHeight: ZimamSpacing.space11, alignment: .leading)
            }
            ForEach(tasks) { task in
                MatrixTaskRow(task: task, projectName: task.projectId.flatMap { names[$0] }, today: today,
                              quadrant: quadrant, onToggle: { onToggle(task) }, onMove: { onMove(task, $0) })
            }
        }
        .padding(ZimamSpacing.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isTargeted ? ZimamColor.brandSoft : ZimamColor.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusLg)
                    .strokeBorder(ZimamColor.focusRing, lineWidth: ZimamLayout.focusRingWidth)
            }
        }
        .taskDropDestination { items in
            onDrop(items.map(\.id))
        } isTargeted: { on in
            onTargeted(on)
        }
    }
}

/// A quadrant's icon, name and count, in the quadrant's colour; the name always goes with it.
struct QuadrantHeader: View {
    let quadrant: PriorityQuadrant
    let count: Int

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            Image(systemName: quadrant.systemImage)
                .font(ZimamType.headline)
            Text(quadrant.title)
                .font(ZimamType.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatter.number(count))
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.onQuadrant)
                .padding(.horizontal, ZimamSpacing.space2)
                .background(quadrant.color, in: Capsule())
        }
        .foregroundStyle(quadrant.color)
        .frame(minHeight: ZimamSpacing.space11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(quadrant.title)، \(ArabicCount.tasks(count, locale: formatter.locale))")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A task in a quadrant: the completion circle, the title, and its due day (its time when today).
struct MatrixTaskRow: View {
    let task: TaskItem
    let projectName: String?
    let today: String
    let quadrant: PriorityQuadrant
    let onToggle: () -> Void
    let onMove: (PriorityQuadrant) -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        NavigationLink(value: TaskRoute(id: task.id)) {
            HStack(alignment: .top, spacing: ZimamSpacing.space1) {
                CompletionCircle(isDone: task.isDone, font: ZimamType.headline, action: onToggle)

                VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                    Text(task.title)
                        .font(ZimamType.callout)
                        .foregroundStyle(task.isDone ? ZimamColor.inkFaint : ZimamColor.ink)
                        .strikethrough(task.isDone)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let due {
                        DateChip(text: due, overdue: !task.isDone && (task.dueDate ?? today) < today)
                    }
                    if let projectName {
                        Text(projectName)
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, ZimamSpacing.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(TaskDragItem(id: task.id)) { TaskDragPreview(title: task.title) }
        .contextMenu {
            Button(task.isDone ? "إلغاء الإنجاز" : "إنجاز", systemImage: "checkmark.circle", action: onToggle)
            Menu("نقل إلى") {
                ForEach(others) { target in
                    Button(target.title, systemImage: target.systemImage) { onMove(target) }
                }
            }
        }
        .accessibilityActions {
            ForEach(others) { target in
                Button("نقل إلى «\(target.title)»") { onMove(target) }
            }
        }
    }

    private var others: [PriorityQuadrant] {
        PriorityQuadrant.allCases.filter { $0 != quadrant }
    }

    /// «اليوم، ٣:٠٠ م» for a time today, the day's label otherwise.
    private var due: String? {
        guard let day = task.dueDate, let date = formatter.date(fromDay: day) else { return nil }
        let label = formatter.label(for: date)
        guard day == today, task.duePrayer == nil, let time = task.dueTime else { return label }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        guard parts.count >= 2, let at = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date) else {
            return label
        }
        return "\(label)، \(formatter.time(at))"
    }
}
