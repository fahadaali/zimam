#if os(iOS) || os(watchOS)
import SwiftUI
import WidgetKit
import ZimamKit

/// The accessory widgets: the iPhone Lock Screen (ZimamWidgets) and the watch complications
/// (ZimamWatchWidgets) share these views; each target brings its own provider of
/// `GlanceSnapshot`.
struct GlanceEntry: TimelineEntry {
    let date: Date
    let snapshot: GlanceSnapshot

    static let placeholder = GlanceEntry(date: Date(), snapshot: .placeholder)
}

/// The view for each accessory family, in Arabic and right to left.
struct GlanceView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, ZimamLocale.current)
            // Opens «اليوم» rather than the last screen (the watch app has one screen anyway).
            .widgetURL(AppLink.today.url)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            GlanceCircular(entry: entry)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryInline:
            GlanceInline(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        #if os(watchOS)
        case .accessoryCorner:
            GlanceCorner(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        #endif
        default:
            GlanceRectangular(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
    }
}

/// Colors by rendering mode. The Lock Screen draws accessory widgets "vibrant" (one tone from
/// the wallpaper) and the watch may draw them "accented" (tinted); there the hierarchy comes
/// from the system's primary and secondary levels. In full color (the watch's colorful faces)
/// they use the Zimam tokens, with sand for the prayer time as everywhere else.
private struct GlanceStyle {
    let mode: WidgetRenderingMode

    private var isFullColor: Bool { mode == .fullColor }

    var primary: AnyShapeStyle {
        isFullColor ? AnyShapeStyle(ZimamColor.ink) : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }

    var secondary: AnyShapeStyle {
        isFullColor ? AnyShapeStyle(ZimamColor.inkMuted) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }

    var prayer: AnyShapeStyle {
        isFullColor ? AnyShapeStyle(ZimamColor.sand) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }

    /// The completion ring follows the completion circle, which turns brand when done.
    var progress: Color {
        ZimamColor.brand
    }
}

private func glanceFormatter(for snapshot: GlanceSnapshot) -> DualDateFormatter {
    DualDateFormatter(primary: CalendarKind(rawValue: snapshot.calendar) ?? .hijri, locale: ZimamLocale.current)
}

private func glanceNumber(_ value: Int) -> String {
    value.formatted(.number.locale(ZimamLocale.current))
}

/// When the next task falls: its prayer phrase and, if known, the clock time; or the clock time.
private func whenText(_ item: GlanceSnapshot.Item, formatter: DualDateFormatter) -> String? {
    let clock = item.time.map { formatter.time($0) }
    if let prayer = item.prayerText {
        return clock.map { "\(prayer)، \($0)" } ?? prayer
    }
    if item.isOverdue { return "متأخرة" }
    return clock
}

// MARK: Circular

/// How many tasks are still open today, inside a ring of what is done.
private struct GlanceCircular: View {
    let entry: GlanceEntry
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let snapshot = entry.snapshot
        let style = GlanceStyle(mode: mode)
        if snapshot.isSignedIn {
            Gauge(value: snapshot.progress) {
                Text("اليوم")
                    .font(ZimamType.caption)
            } currentValueLabel: {
                Text(glanceNumber(snapshot.openCount))
                    .font(ZimamType.headline)
                    .foregroundStyle(style.primary)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(style.progress)
            .widgetAccentable()
            .accessibilityLabel("\(ArabicCount.tasks(snapshot.openCount, locale: ZimamLocale.current)) مفتوحة اليوم")
        } else {
            Image(systemName: "checklist")
                .font(ZimamType.title)
                .foregroundStyle(style.secondary)
                .widgetAccentable()
                .accessibilityLabel("سجّل الدخول في زمام")
        }
    }
}

// MARK: Rectangular

/// The next task with its time or prayer, under the count of today's open tasks.
private struct GlanceRectangular: View {
    let entry: GlanceEntry
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let snapshot = entry.snapshot
        let style = GlanceStyle(mode: mode)
        let dates = glanceFormatter(for: snapshot)
        VStack(alignment: .leading, spacing: 0) {
            if !snapshot.isSignedIn {
                header("زمام", style: style)
                Text("سجّل الدخول في زمام لتظهر مهامك هنا.")
                    .font(ZimamType.caption)
                    .foregroundStyle(style.secondary)
                    .lineLimit(2)
            } else if let next = snapshot.next(at: entry.date) {
                header("\(ArabicCount.tasks(snapshot.openCount, locale: dates.locale)) اليوم", style: style)
                Text(next.title)
                    .font(ZimamType.headline)
                    .foregroundStyle(style.primary)
                    .lineLimit(whenText(next, formatter: dates) == nil ? 2 : 1)
                if let when = whenText(next, formatter: dates) {
                    HStack(spacing: ZimamSpacing.space1) {
                        if next.prayerText != nil {
                            Image(systemName: "moon.stars")
                                .accessibilityHidden(true)
                        }
                        Text(when)
                            .lineLimit(1)
                    }
                    .font(ZimamType.caption)
                    .foregroundStyle(next.prayerText != nil ? style.prayer : style.secondary)
                }
            } else {
                header(dates.dual(entry.date), style: style)
                Text("لا مهام اليوم.")
                    .font(ZimamType.headline)
                    .foregroundStyle(style.primary)
                    .lineLimit(1)
                Text("يومك لك.")
                    .font(ZimamType.caption)
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ text: String, style: GlanceStyle) -> some View {
        Text(text)
            .font(ZimamType.caption)
            .foregroundStyle(style.secondary)
            .lineLimit(1)
            .widgetAccentable()
    }
}

// MARK: Inline

/// One line above the clock: the next task's title.
private struct GlanceInline: View {
    let entry: GlanceEntry

    var body: some View {
        let snapshot = entry.snapshot
        if !snapshot.isSignedIn {
            Text("زمام")
        } else if let next = snapshot.next(at: entry.date) {
            Label(next.title, systemImage: "circle")
        } else {
            Label("لا مهام اليوم", systemImage: "checkmark.circle")
        }
    }
}

// MARK: Corner (watch)

#if os(watchOS)
/// The count in the corner, and the next task's title along the curve.
private struct GlanceCorner: View {
    let entry: GlanceEntry
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let snapshot = entry.snapshot
        let style = GlanceStyle(mode: mode)
        Text(snapshot.isSignedIn ? glanceNumber(snapshot.openCount) : "زمام")
            .font(ZimamType.headline)
            .foregroundStyle(style.primary)
            .widgetAccentable()
            .widgetLabel {
                Text(label(snapshot))
            }
            .accessibilityLabel(label(snapshot))
    }

    private func label(_ snapshot: GlanceSnapshot) -> String {
        guard snapshot.isSignedIn else { return "سجّل الدخول" }
        return snapshot.next(at: entry.date)?.title ?? "لا مهام اليوم"
    }
}
#endif

#endif
