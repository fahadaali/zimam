import SwiftUI
import ZimamKit

// The pieces of GanttView: the groups and their headers. The rows and bars are in GanttRow.swift,
// the axis in GanttAxis.swift and «تغيير المدة…» in SpanEditSheet.swift. Positions are leading
// offsets (`padding(.leading:)`), so the chart mirrors itself in Arabic: the first day is at the
// right and time runs leftwards.

// MARK: Data

/// A task on the timeline with its days.
struct GanttRowData: Identifiable {
    let task: TaskItem
    let span: DaySpan

    var id: UUID { task.id }
}

/// A section of a project, or a project in the whole timeline, with its rows by start day.
struct GanttGroup: Identifiable {
    let id: String
    /// nil for a project's tasks without a section when it has no sections at all.
    let title: String?
    let rows: [GanttRowData]

    /// The column of the group's earliest start, where its title is written.
    func leadingColumn(in range: TimelineRange) -> CGFloat {
        guard let first = rows.map(\.span.start).min(), let index = range.index(of: first) else { return 0 }
        return CGFloat(min(max(index, 0), range.dayCount - 1))
    }
}

// MARK: Rows

/// The line at today, through every row and the axis.
struct GanttTodayLine: View {
    var body: some View {
        Rectangle()
            .fill(ZimamColor.timelineToday)
            .frame(width: ZimamLayout.focusRingWidth)
            .accessibilityHidden(true)
    }
}

/// A group's name, written above its rows where its earliest task starts.
struct GanttGroupHeader: View {
    let title: String
    let leadingOffset: CGFloat
    let width: CGFloat
    let height: CGFloat
    let todayX: CGFloat?

    var body: some View {
        ZStack(alignment: .leading) {
            if let todayX {
                GanttTodayLine().padding(.leading, max(todayX - ZimamLayout.focusRingWidth / 2, 0))
            }
            Text(title)
                .font(ZimamType.headline)
                .foregroundStyle(ZimamColor.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, leadingOffset + ZimamSpacing.space1)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(ZimamColor.surfaceSunken)
    }
}
