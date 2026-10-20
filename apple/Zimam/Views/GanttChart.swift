import SwiftUI
import ZimamKit

/// GanttView's chart: the axis pinned over the groups and their rows, scrolled to today when it
/// appears, when «اليوم» asks (`todayRequest`) and when the zoom changes.
struct GanttChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let groups: [GanttGroup]
    let range: TimelineRange
    let zoom: GanttView.Zoom
    let kind: CalendarKind
    let today: String
    let rowHeight: CGFloat
    /// Bumped to scroll to today.
    let todayRequest: Int
    let selected: UUID?
    let onSelect: (TaskItem) -> Void
    let onOpen: (TaskItem) -> Void
    let onCommit: (TaskItem, DaySpan) -> Void
    let onEdit: (TaskItem) -> Void
    let onComplete: (TaskItem) -> Void

    var body: some View {
        let dayWidth = zoom == .days ? ZimamSpacing.space11 : ZimamSpacing.space2
        let width = dayWidth * CGFloat(range.dayCount)
        let todayIndex = range.index(of: today).flatMap { (0 ..< range.dayCount).contains($0) ? $0 : nil }
        // Once for the chart, not per row.
        let todayX = todayIndex.map { CGFloat($0) * dayWidth + dayWidth / 2 }
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(groups) { group in
                            if let title = group.title {
                                GanttGroupHeader(title: title, leadingOffset: group.leadingColumn(in: range) * dayWidth,
                                                 width: width, height: rowHeight, todayX: todayX)
                            }
                            ForEach(group.rows) { row in
                                GanttRow(task: row.task, span: row.span, range: range, dayWidth: dayWidth, height: rowHeight,
                                         todayX: todayX, isSelected: selected == row.task.id,
                                         onSelect: { onSelect(row.task) }, onOpen: { onOpen(row.task) },
                                         onCommit: { onCommit(row.task, $0) },
                                         onEdit: { onEdit(row.task) },
                                         onComplete: { onComplete(row.task) })
                            }
                        }
                    } header: {
                        GanttAxis(range: range, zoom: zoom, dayWidth: dayWidth, kind: kind, today: today,
                                  todayIndex: todayIndex)
                    }
                }
                .frame(width: width, alignment: .leading)
                // Room for the add button over the last row.
                .padding(.bottom, ZimamSpacing.space11 + ZimamSpacing.space8)
            }
            // A chart shorter than the screen starts under the axis, not centred in the space.
            .defaultScrollAnchor(.top, for: .alignment)
            .onAppear { scrollToToday(proxy) }
            .onChange(of: todayRequest) { _, _ in scrollToToday(proxy) }
            .onChange(of: zoom) { _, _ in scrollToToday(proxy) }
        }
    }

    private func scrollToToday(_ proxy: ScrollViewProxy) {
        // After the layout, so the marker exists: the task resumes on a later turn of the main
        // actor, once SwiftUI has laid out the rows and the axis.
        Task { @MainActor in
            await Task.yield()
            withAnimation(.zimam(reduceMotion: reduceMotion)) {
                proxy.scrollTo(GanttAxis.todayID, anchor: .top)
            }
        }
    }
}
