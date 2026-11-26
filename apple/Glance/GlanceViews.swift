#if os(iOS) || os(watchOS)
import SwiftUI
import WidgetKit
import ZimamKit

/// The accessory widgets: the iPhone Lock Screen (ZimamWidgets) and the watch complications
/// (ZimamWatchWidgets) share these views; each target brings its own provider of
/// `GlanceSnapshot`.
///
/// Task titles are `privacySensitive`: while the iPhone is locked, or the watch is locked or its
/// wrist is down, the system shows a placeholder in their place. Counts, dates and prayer times
/// stay visible.
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

/// How many tasks are still open today, inside a ring of what is done. The number is sized to the
/// ring's centre, so it fills it on every watch size and on the Lock Screen.
private struct GlanceCircular: View {
    let entry: GlanceEntry
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
        let snapshot = entry.snapshot
        let style = GlanceStyle(mode: mode)
        if snapshot.isSignedIn {
            Gauge(value: snapshot.progress) {
                Text("اليوم")
                    .widgetFont(.caption)
            } currentValueLabel: {
                Text(glanceNumber(snapshot.openCount))
                    .lineLimit(1)
                    .minimumScaleFactor(AccessoryRound.shrink)
                    .widgetFont(.headline)
                    .foregroundStyle(style.primary)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(style.progress)
            .widgetAccentable()
            .widgetTextScale(AccessoryRound.scale(side: side, lines: [.headline], share: AccessoryRound.insideRing,
                                                  dynamicType: dynamicType))
            .accessibilityLabel("\(ArabicCount.tasks(snapshot.openCount, locale: ZimamLocale.current)) مفتوحة اليوم")
        } else {
            Image(systemName: "checklist")
                .widgetFont(.title)
                .foregroundStyle(style.secondary)
                .widgetAccentable()
                .widgetTextScale(AccessoryRound.scale(side: side, lines: [.title], share: AccessoryRound.symbol,
                                                      dynamicType: dynamicType))
                .accessibilityLabel("سجّل الدخول في زمام")
        }
    }
}

// MARK: Rectangular

/// The next task with its time or prayer, under the count of today's open tasks. The lines fill the
/// height they are given: on a small watch the count gives way before the text gets too small to
/// read, on the larger Lock Screen the text grows, and a title too long for one line takes two
/// when that keeps the other lines.
private struct GlanceRectangular: View {
    let entry: GlanceEntry
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
        let snapshot = entry.snapshot
        let style = GlanceStyle(mode: mode)
        let dates = glanceFormatter(for: snapshot)
        if !snapshot.isSignedIn {
            let plan = AccessoryPlan.fitting(height: height, dynamicType: dynamicType, header: .caption,
                                             main: .caption, mainLines: 2, detail: nil, drops: .header)
            VStack(alignment: .leading, spacing: 0) {
                if plan.showsHeader {
                    header("زمام", style: style)
                }
                Text("سجّل الدخول في زمام لتظهر مهامك هنا.")
                    .widgetFont(.caption)
                    .foregroundStyle(style.secondary)
                    .lineLimit(plan.mainLines)
            }
            .widgetTextScale(plan.scale)
        } else if let next = snapshot.next(at: entry.date) {
            let when = whenText(next, formatter: dates)
            let count = "\(ArabicCount.tasks(snapshot.openCount, locale: dates.locale)) اليوم"
            let plans = nextPlans(height: height, hasWhen: when != nil)
            if let twoLines = plans.twoLines {
                // The title on one line at the larger size when it fits the width, else on two.
                ViewThatFits(in: .horizontal) {
                    nextTask(next, count: count, when: when, plan: plans.oneLine, style: style)
                    nextTask(next, count: count, when: when, plan: twoLines, style: style)
                }
            } else {
                nextTask(next, count: count, when: when, plan: plans.oneLine, style: style)
            }
        } else {
            let plan = AccessoryPlan.fitting(height: height, dynamicType: dynamicType, header: .caption,
                                             main: .headline, detail: .caption, drops: .detail)
            VStack(alignment: .leading, spacing: 0) {
                if plan.showsHeader {
                    header(dates.dual(entry.date), style: style)
                }
                Text("لا مهام اليوم.")
                    .widgetFont(.headline)
                    .foregroundStyle(style.primary)
                    .lineLimit(1)
                if plan.showsDetail {
                    Text("يومك لك.")
                        .widgetFont(.caption)
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                }
            }
            .widgetTextScale(plan.scale)
        }
    }

    /// The layout with a one-line title, and with a two-line one when it keeps the same lines.
    private func nextPlans(height: CGFloat, hasWhen: Bool) -> (oneLine: AccessoryPlan, twoLines: AccessoryPlan?) {
        let oneLine = AccessoryPlan.fitting(height: height, dynamicType: dynamicType, header: .caption, main: .headline,
                                            mainLines: 1, detail: hasWhen ? .caption : nil, drops: .header)
        let twoLines = AccessoryPlan.fitting(height: height, dynamicType: dynamicType, header: .caption, main: .headline,
                                             mainLines: 2, detail: hasWhen ? .caption : nil, drops: .header)
        let keepsLines = twoLines.showsHeader == oneLine.showsHeader && twoLines.showsDetail == oneLine.showsDetail
        return (oneLine, keepsLines ? twoLines : nil)
    }

    private func nextTask(_ next: GlanceSnapshot.Item, count: String, when: String?, plan: AccessoryPlan,
                          style: GlanceStyle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if plan.showsHeader {
                header(count, style: style)
            }
            Text(next.title)
                .widgetFont(.headline)
                .foregroundStyle(style.primary)
                .lineLimit(plan.mainLines)
                .privacySensitive()
                .widgetTextDirection(of: next.title)
            if plan.showsDetail, let when {
                HStack(spacing: ZimamSpacing.space1) {
                    if next.prayerText != nil {
                        Image(systemName: "moon.stars")
                            .accessibilityHidden(true)
                    }
                    Text(when)
                        .lineLimit(1)
                }
                .widgetFont(.caption)
                .foregroundStyle(next.prayerText != nil ? style.prayer : style.secondary)
            }
        }
        .widgetTextScale(plan.scale)
    }

    private func header(_ text: String, style: GlanceStyle) -> some View {
        Text(text)
            .widgetFont(.caption)
            .foregroundStyle(style.secondary)
            .lineLimit(1)
            .widgetAccentable()
    }
}

// MARK: Inline

/// One line above the clock: the next task's title. Words only, with a mark at the start that sets
/// the title's direction (`WidgetTextDirection.marked`): the system draws this line in the watch's
/// language, where a symbol beside an Arabic title swapped sides on a watch in English.
private struct GlanceInline: View {
    let entry: GlanceEntry

    var body: some View {
        let snapshot = entry.snapshot
        if !snapshot.isSignedIn {
            Text(WidgetTextDirection.marked("زمام"))
        } else if let next = snapshot.next(at: entry.date) {
            Text(WidgetTextDirection.marked(next.title))
                .privacySensitive()
        } else {
            Text(WidgetTextDirection.marked("لا مهام اليوم"))
        }
    }
}

// MARK: Corner (watch)

#if os(watchOS)
/// The count in the corner, and the next task's title along the curve. The corner's centre is
/// small, so the count shrinks to it rather than being cut, and signed out it is the app's symbol
/// (the word «زمام» would not fit), with the words along the curve.
private struct GlanceCorner: View {
    let entry: GlanceEntry
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        let snapshot = entry.snapshot
        let style = GlanceStyle(mode: mode)
        let title = snapshot.isSignedIn ? snapshot.next(at: entry.date)?.title : nil
        centre(snapshot)
            .foregroundStyle(style.primary)
            .widgetAccentable()
            // A plain Text, as the curved label takes: the title gives way to a generic line while
            // private content is hidden (`privacySensitive` elsewhere), and is not read out then.
            .widgetLabel {
                Text(WidgetTextDirection.marked(title.map { isHidden ? "المهمة التالية" : $0 } ?? label(snapshot)))
            }
            .accessibilityLabel(title.map { isHidden ? openLabel(snapshot) : $0 } ?? label(snapshot))
    }

    @ViewBuilder
    private func centre(_ snapshot: GlanceSnapshot) -> some View {
        if snapshot.isSignedIn {
            Text(glanceNumber(snapshot.openCount))
                .lineLimit(1)
                .minimumScaleFactor(AccessoryRound.shrink)
                .widgetFont(.headline)
        } else {
            Image(systemName: "checklist")
                .widgetFont(.headline)
        }
    }

    private var isHidden: Bool { redaction.contains(.privacy) }

    private func label(_ snapshot: GlanceSnapshot) -> String {
        snapshot.isSignedIn ? "لا مهام اليوم" : "سجّل الدخول"
    }

    private func openLabel(_ snapshot: GlanceSnapshot) -> String {
        "\(ArabicCount.tasks(snapshot.openCount, locale: ZimamLocale.current)) مفتوحة اليوم"
    }
}
#endif

#endif
