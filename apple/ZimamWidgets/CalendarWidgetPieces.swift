import SwiftUI
import WidgetKit
import ZimamKit

// The pieces the month, week and upcoming widgets share: the weekday header, a week row's lanes of
// chips and bars, and the links over each day column.

/// Weekday initials over the columns, the week's first day at the leading edge.
struct WeekdayHeader: View {
    let grid: CalendarGrid
    let dates: DualDateFormatter
    let tone: WidgetTone

    var body: some View {
        let symbols = dates.weekdaySymbols(grid.weekdayOrder, short: true)
        HStack(spacing: 0) {
            ForEach(symbols.indices, id: \.self) { index in
                Text(symbols[index])
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
                    .padding(.leading, ZimamSpacing.space1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A week row's lanes as `WeekLanes` laid them out: bars, chips and «+n», column 0 at the leading
/// edge. Each lane is one row of segments, so the right-to-left layout places them.
struct WidgetLaneRows: View {
    let layout: WeekLanes
    let snapshot: WidgetSnapshot
    let columnWidth: CGFloat
    let laneHeight: CGFloat
    /// The week widget shows each chip's time over its title.
    let showsTime: Bool
    let tone: WidgetTone

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<layout.laneCount, id: \.self) { lane in
                HStack(spacing: 0) {
                    ForEach(layout.segments(inLane: lane)) { segment in
                        content(segment)
                            .frame(width: columnWidth * CGFloat(segment.columnCount), height: laneHeight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ segment: WeekLanes.Segment) -> some View {
        if let placement = segment.placement {
            switch placement.content {
            case .task(let task):
                if let item = snapshot.item(task.id) {
                    WidgetTaskChip(item: item, time: showsTime && !item.isSpan ? chipTime(item) : nil,
                                   continuesBefore: placement.continuesBefore, continuesAfter: placement.continuesAfter,
                                   tone: tone)
                        .padding(.vertical, WidgetMetrics.gap / 2)
                        .padding(.leading, placement.continuesBefore ? 0 : WidgetMetrics.gap / 2)
                        .padding(.trailing, placement.continuesAfter ? 0 : WidgetMetrics.gap / 2)
                } else {
                    Color.clear
                }
            case .more(let count):
                WidgetMoreLabel(count: count, tone: tone, locale: snapshot.formatter.locale)
            }
        } else {
            Color.clear
        }
    }

    /// «١٦:٤٢», or the prayer's name for a task tied to one.
    private func chipTime(_ item: WidgetItem) -> String? {
        if let prayer = item.prayer { return prayer.arabicName }
        return item.time.map { snapshot.formatter.compactTime($0) }
    }
}

/// A transparent link over each day column, to open that day in the app's calendar.
struct WidgetDayLinks: View {
    let days: [String]
    let columnWidth: CGFloat
    let label: (String) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                Link(destination: AppLink.day(day).url) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .frame(width: columnWidth)
                .accessibilityLabel(label(day))
            }
        }
    }
}
