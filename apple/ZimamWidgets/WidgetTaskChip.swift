import SwiftUI
import WidgetKit
import ZimamKit

/// A task on a calendar day: a colored edge (its priority) and its title, or its time over its
/// title when `time` is given. A task over several days is a tinted bar with its title.
struct WidgetTaskChip: View {
    let item: WidgetItem
    var time: String?
    var continuesBefore = false
    var continuesAfter = false
    let tone: WidgetTone

    var body: some View {
        HStack(spacing: ZimamSpacing.space1 / 2) {
            if !continuesBefore {
                Capsule()
                    .fill(item.priority == .none ? tone.strong : tone.priority(item.priority))
                    .frame(width: WidgetMetrics.stripe)
                    .padding(.vertical, WidgetMetrics.gap)
                    .widgetAccentable(item.priority != .none)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let time {
                    Text(time)
                        .font(ZimamType.caption)
                        .foregroundStyle(item.prayer != nil ? tone.prayer : tone.muted)
                        .lineLimit(1)
                }
                Text(item.title)
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, continuesBefore ? ZimamSpacing.space1 : WidgetMetrics.gap)
        .padding(.trailing, WidgetMetrics.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(item.isSpan ? tone.barFill(item.priority) : tone.fill, in: shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([time, item.title, priorityLabel(item.priority)].compactMap { $0 }.joined(separator: "، "))
    }

    /// Square ends where the bar goes on into the next or previous week.
    private var shape: UnevenRoundedRectangle {
        let radius = ZimamRadius.radiusSm
        return UnevenRoundedRectangle(topLeadingRadius: continuesBefore ? 0 : radius,
                                      bottomLeadingRadius: continuesBefore ? 0 : radius,
                                      bottomTrailingRadius: continuesAfter ? 0 : radius,
                                      topTrailingRadius: continuesAfter ? 0 : radius)
    }
}
