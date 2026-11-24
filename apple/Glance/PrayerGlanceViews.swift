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

/// «العصر بعد ١:١٢:٠٥» above the clock.
private struct PrayerInline: View {
    let entry: PrayerEntry

    var body: some View {
        prayerLine(entry.state)
    }
}

/// «العصر بعد ١:١٢:٠٥» or «العصر منذ ١٢:٠٥», with the moon: the inline widget, and the watch
/// corner's curve.
private func prayerLine(_ state: PrayerClock.State?) -> Text {
    guard let state else { return Text("\(Image(systemName: "moon.stars")) \(noPlaceText)") }
    switch state {
    case .since(let prayer, let adhan):
        return Text("\(Image(systemName: "moon.stars")) \(prayer.arabicName) منذ \(Text(adhan, style: .timer))")
    case .until(let prayer, let time):
        return Text("\(Image(systemName: "moon.stars")) \(prayer.arabicName) بعد \(Text(time, style: .timer))")
    }
}

#if os(watchOS)
// MARK: Corner

/// The moon in the corner, and the prayer with its countdown along the curve: the corner's centre
/// is too small for a countdown with hours, which the curve has room for.
private struct PrayerCorner: View {
    let entry: PrayerEntry

    var body: some View {
        Image(systemName: "moon.stars")
            .widgetFont(.title)
            .widgetAccentable()
            .widgetLabel {
                prayerLine(entry.state)
            }
            .accessibilityLabel(entry.state?.title ?? noPlaceText)
    }
}
#endif
#endif
