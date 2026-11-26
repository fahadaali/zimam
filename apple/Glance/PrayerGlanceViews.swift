#if os(iOS) || os(watchOS)
import SwiftUI
import WidgetKit
import ZimamKit

/// The prayer accessory widgets: the iPhone Lock Screen (ZimamWidgets/PrayerWidget.swift) and the
/// watch complications (ZimamWatchWidgets) share these views. The countdown, and for half an hour
/// after the adhan the time since it, is the system's own timer, so it moves every second without
/// new entries.
struct PrayerAccessoryView: View {
    let entry: PrayerEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, ZimamLocale.current)
            .widgetURL(AppLink.prayer.url)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            PrayerCircular(entry: entry)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryInline:
            PrayerInline(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        #if os(watchOS)
        case .accessoryCorner:
            PrayerCorner(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        #endif
        default:
            PrayerRectangular(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
    }
}

/// Sand in full colour (the watch's colourful faces), as prayer times are everywhere else; the
/// system's levels on the Lock Screen and tinted faces.
private struct PrayerGlanceStyle {
    let mode: WidgetRenderingMode

    var prayer: AnyShapeStyle {
        mode == .fullColor ? AnyShapeStyle(ZimamColor.sand) : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }

    var secondary: AnyShapeStyle {
        mode == .fullColor ? AnyShapeStyle(ZimamColor.inkMuted) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }
}

private let noPlaceText = "حدّد موقعك في زمام"

// MARK: Circular

/// The prayer's name over its countdown, sized to the circle: a countdown with hours shrinks to the
/// circle's width rather than being cut.
private struct PrayerCircular: View {
    let entry: PrayerEntry
    @Environment(\.widgetRenderingMode) private var mode
    @ScaledMetric(relativeTo: .body) private var dynamicType: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            content(side: side)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder
    private func content(side: CGFloat) -> some View {
        let style = PrayerGlanceStyle(mode: mode)
        if let state = entry.state {
            VStack(spacing: 0) {
                Text(state.prayer.arabicName)
                    .lineLimit(1)
                    .widgetFont(.caption)
                    .widgetAccentable()
                Text(state.time, style: .timer)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(AccessoryRound.shrink)
                    .widgetFont(.caption)
            }
            .frame(width: side * AccessoryRound.width)
            .foregroundStyle(style.prayer)
            .widgetTextScale(AccessoryRound.scale(side: side, lines: [.caption, .caption], share: AccessoryRound.twoLines,
                                                  dynamicType: dynamicType))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.title)
        } else {
            Image(systemName: "moon.stars")
                .widgetFont(.title)
                .foregroundStyle(style.secondary)
                .widgetAccentable()
                .widgetTextScale(AccessoryRound.scale(side: side, lines: [.title], share: AccessoryRound.symbol,
                                                      dynamicType: dynamicType))
                .accessibilityLabel(noPlaceText)
        }
    }
}

// MARK: Rectangular

/// The state, the countdown, and the adhan's time, filling the height they are given: on a small
/// watch the adhan's time gives way before the text gets too small to read, and on the larger Lock
/// Screen the text grows.
private struct PrayerRectangular: View {
    let entry: PrayerEntry
    @Environment(\.widgetRenderingMode) private var mode
    @ScaledMetric(relativeTo: .body) private var dynamicType: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            content(height: geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
    }

    @ViewBuilder
    private func content(height: CGFloat) -> some View {
        let style = PrayerGlanceStyle(mode: mode)
        let formatter = DualDateFormatter(locale: ZimamLocale.current)
        if let state = entry.state {
            let plan = AccessoryPlan.fitting(height: height, dynamicType: dynamicType, header: .caption, main: .headline,
                                             detail: .caption, drops: .detail)
            VStack(alignment: .leading, spacing: 0) {
                if plan.showsHeader {
                    HStack(spacing: ZimamSpacing.space1) {
                        Image(systemName: "moon.stars")
                            .accessibilityHidden(true)
                        Text(state.title)
                            .lineLimit(1)
                    }
                    .widgetFont(.caption)
                    .foregroundStyle(style.secondary)
                    .widgetAccentable()
                }
                Text(state.time, style: .timer)
                    .monospacedDigit()
                    .lineLimit(1)
                    .widgetFont(.headline)
                    .foregroundStyle(style.prayer)
                if plan.showsDetail {
                    Text("\(state.prayer.arabicName)، \(formatter.time(state.time))")
                        .widgetFont(.caption)
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                }
            }
            .widgetTextScale(plan.scale)
        } else {
            let plan = AccessoryPlan.fitting(height: height, dynamicType: dynamicType, header: .caption, main: .headline,
                                             mainLines: 2, detail: nil, drops: .header)
            VStack(alignment: .leading, spacing: 0) {
                if plan.showsHeader {
                    Text("أوقات الصلاة")
                        .widgetFont(.caption)
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                        .widgetAccentable()
                }
                Text(noPlaceText)
                    .widgetFont(.headline)
                    .foregroundStyle(style.prayer)
                    .lineLimit(plan.mainLines)
            }
            .widgetTextScale(plan.scale)
        }
    }
}

// MARK: Inline

/// «الفجر بعد ٤٢ د» above the clock. The system draws this line in the face's own font and size
/// and ignores the app's, so the text alone can make it fit: the fuller of two that fits the face's
/// width (`ViewThatFits`), down to the prayer and its adhan in 24 hours («الفجر ٤:٤٢»).
private struct PrayerInline: View {
    let entry: PrayerEntry

    var body: some View {
        let lines = prayerLines(entry)
        ViewThatFits(in: .horizontal) {
            Text(lines.full)
            Text(lines.short)
        }
    }
}

/// The prayer's line in two lengths, for the inline widget and the watch corner's curve, in words
/// and digits only: a symbol beside Arabic text the system draws in the watch's language swapped
/// sides on a watch in English, and the line is short.
/// - full: «الفجر بعد ٤٢ د» in the last hour before the adhan, «الفجر الآن» at it, «الفجر من ١٢ د»
///   in the half hour after it, and further from it «الفجر ٤:٤٢ ص», the adhan's time.
/// - short: the prayer and its adhan in 24 hours, «الفجر ٤:٤٢».
/// Each starts with a right-to-left mark, so it reads from the right whatever the watch's language.
private func prayerLines(_ entry: PrayerEntry) -> (full: String, short: String) {
    guard let state = entry.state else {
        return (WidgetTextDirection.marked(noPlaceText), WidgetTextDirection.marked("حدّد موقعك"))
    }
    let formatter = DualDateFormatter(locale: ZimamLocale.current)
    let name = state.prayer.arabicName
    let short = "\(name) \(formatter.compactTime(state.time))"
    var full = "\(name) \(formatter.time(state.time))"
    if !entry.countdownHasHours, let minutes = entry.minutes {
        switch state {
        case .until:
            full = "\(name) بعد \(formatter.number(max(minutes, 1))) د"
        case .since:
            full = minutes == 0 ? "\(name) الآن" : "\(name) من \(formatter.number(minutes)) د"
        }
    }
    return (WidgetTextDirection.marked(full), WidgetTextDirection.marked(short))
}

#if os(watchOS)
// MARK: Corner

/// The moon in the corner, and the prayer with its countdown or adhan time along the curve
/// (`prayerLines`): the corner's centre is too small for the countdown.
private struct PrayerCorner: View {
    let entry: PrayerEntry

    var body: some View {
        Image(systemName: "moon.stars")
            .widgetFont(.title)
            .widgetAccentable()
            .widgetLabel {
                Text(prayerLines(entry).full)
            }
            .accessibilityLabel(entry.state?.title ?? noPlaceText)
    }
}
#endif
#endif
