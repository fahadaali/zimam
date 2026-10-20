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

/// «المتبقي على العصر» or «مضى على أذان العصر».
func prayerStateTitle(_ state: PrayerClock.State) -> String {
    switch state {
    case .since(let prayer, _): "مضى على أذان \(prayer.arabicName)"
    case .until(let prayer, _): "المتبقي على \(prayer.arabicName)"
    }
}

private let noPlaceText = "حدّد موقعك في زمام"

// MARK: Circular

/// The prayer's name over its countdown.
private struct PrayerCircular: View {
    let entry: PrayerEntry
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let style = PrayerGlanceStyle(mode: mode)
        if let state = entry.state {
            VStack(spacing: 0) {
                Text(state.prayer.arabicName)
                    .font(ZimamType.caption)
                    .widgetAccentable()
                Text(state.time, style: .timer)
                    .font(ZimamType.caption)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(style.prayer)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(prayerStateTitle(state))
        } else {
            Image(systemName: "moon.stars")
                .font(ZimamType.title)
                .foregroundStyle(style.secondary)
                .widgetAccentable()
                .accessibilityLabel(noPlaceText)
        }
    }
}

// MARK: Rectangular

/// The state, the countdown, and the adhan's time.
private struct PrayerRectangular: View {
    let entry: PrayerEntry
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let style = PrayerGlanceStyle(mode: mode)
        let formatter = DualDateFormatter(locale: ZimamLocale.current)
        VStack(alignment: .leading, spacing: 0) {
            if let state = entry.state {
                HStack(spacing: ZimamSpacing.space1) {
                    Image(systemName: "moon.stars")
                        .accessibilityHidden(true)
                    Text(prayerStateTitle(state))
                        .lineLimit(1)
                }
                .font(ZimamType.caption)
                .foregroundStyle(style.secondary)
                .widgetAccentable()
                Text(state.time, style: .timer)
                    .font(ZimamType.headline)
                    .monospacedDigit()
                    .foregroundStyle(style.prayer)
                Text("\(state.prayer.arabicName)، \(formatter.time(state.time))")
                    .font(ZimamType.caption)
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
            } else {
                Text("أوقات الصلاة")
                    .font(ZimamType.caption)
                    .foregroundStyle(style.secondary)
                    .widgetAccentable()
                Text(noPlaceText)
                    .font(ZimamType.headline)
                    .foregroundStyle(style.prayer)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Inline

/// «العصر بعد ١:١٢:٠٥» above the clock.
private struct PrayerInline: View {
    let entry: PrayerEntry

    var body: some View {
        if let state = entry.state {
            switch state {
            case .since(let prayer, let adhan):
                Text("\(Image(systemName: "moon.stars")) \(prayer.arabicName) منذ \(Text(adhan, style: .timer))")
            case .until(let prayer, let time):
                Text("\(Image(systemName: "moon.stars")) \(prayer.arabicName) بعد \(Text(time, style: .timer))")
            }
        } else {
            Text("\(Image(systemName: "moon.stars")) \(noPlaceText)")
        }
    }
}

#if os(watchOS)
// MARK: Corner

/// The countdown in the corner, with the prayer's name along the edge.
private struct PrayerCorner: View {
    let entry: PrayerEntry

    var body: some View {
        if let state = entry.state {
            Text(state.time, style: .timer)
                .font(ZimamType.caption)
                .monospacedDigit()
                .widgetAccentable()
                .widgetLabel(prayerStateTitle(state))
        } else {
            Image(systemName: "moon.stars")
                .font(ZimamType.title)
                .widgetAccentable()
                .widgetLabel(noPlaceText)
        }
    }
}
#endif
#endif
