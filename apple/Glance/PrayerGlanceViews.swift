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

/// «العصر بعد ٤٢:٠٥» above the clock. The system draws this line in the face's own font and size
/// and ignores the app's, so on a face with a short line or a large text size the text alone can
/// make it fit: the fullest of three that fits the face's width (`ViewThatFits`), down to the
/// prayer and its adhan in 24 hours («☾ الفجر ٤:٤٢»), which fits every face.
private struct PrayerInline: View {
    let entry: PrayerEntry

    var body: some View {
        let lines = prayerLines(entry)
        ViewThatFits(in: .horizontal) {
            lines.full
            lines.plain
            lines.short
        }
    }
}

/// The prayer's line in three lengths, for the inline widget and the watch corner's curve.
/// - full: «☾ العصر بعد ٤٢:٠٥» in the last hour before the adhan, «☾ العصر منذ ١٢:٠٥» half an hour
///   after it, and further from it «☾ الفجر ٤:٤٢ ص», the adhan's time, since a countdown with hours
///   («٨:٣١:٢٢») is wider than the line on most faces.
/// - plain: the same without the moon.
/// - short: the prayer and its adhan in 24 hours, «☾ الفجر ٤:٤٢».
private func prayerLines(_ entry: PrayerEntry) -> (full: Text, plain: Text, short: Text) {
    let moon = Image(systemName: "moon.stars")
    guard let state = entry.state else {
        return (Text("\(moon) \(noPlaceText)"), Text(noPlaceText), Text("\(moon) حدّد موقعك"))
    }
    let formatter = DualDateFormatter(locale: ZimamLocale.current)
    let name = state.prayer.arabicName
    let short = Text("\(moon) \(name) \(formatter.compactTime(state.time))")
    let words: Text
    if entry.countdownHasHours {
        words = Text("\(name) \(formatter.time(state.time))")
    } else {
        switch state {
        case .since(_, let adhan):
            words = Text("\(name) منذ \(Text(adhan, style: .timer))")
        case .until(_, let time):
            words = Text("\(name) بعد \(Text(time, style: .timer))")
        }
    }
    return (Text("\(moon) \(words)"), words, short)
}

#if os(watchOS)
// MARK: Corner

/// The moon in the corner, and the prayer with its countdown or adhan time along the curve
/// (`prayerLines`, without a second moon): the corner's centre is too small for the countdown.
private struct PrayerCorner: View {
    let entry: PrayerEntry

    var body: some View {
        Image(systemName: "moon.stars")
            .widgetFont(.title)
            .widgetAccentable()
            .widgetLabel {
                prayerLines(entry).plain
            }
            .accessibilityLabel(entry.state?.title ?? noPlaceText)
    }
}
#endif
#endif
