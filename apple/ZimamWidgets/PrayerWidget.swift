import SwiftUI
import WidgetKit
import ZimamKit

/// «الصلاة القادمة»: the time left until the next prayer, and for half an hour after an adhan the
/// time since it, then the next prayer. Small: the countdown. Medium: with today's times. Large:
/// with today's times, sunrise and the dual date. On the iPhone Lock Screen too, with the watch
/// complications' views (Glance/PrayerGlanceViews.swift).
struct PrayerWidget: Widget {
    static let kind = ZimamShared.WidgetKind.prayer

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: PrayerProvider()) { entry in
            PrayerWidgetView(entry: entry)
        }
        .configurationDisplayName("الصلاة القادمة")
        .description("المتبقي على الصلاة القادمة، وما مضى على الأذان، ومواقيت اليوم.")
        .supportedFamilies(Self.families)
    }

    #if os(iOS)
    private static let families: [WidgetFamily] = [
        .systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline,
    ]
    #else
    private static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
    #endif
}

/// The place the app saved (or picked on the map) and the account's method and madhab. The app
/// reloads the widget when any of them changes.
struct PrayerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PrayerEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (PrayerEntry) -> Void) {
        let place = SharedSettings.prayerPlace()
        completion(context.isPreview && place == nil ? .placeholder : PrayerEntry(date: Date(), place: place))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PrayerEntry>) -> Void) {
        completion(PrayerEntry.timeline(place: SharedSettings.prayerPlace()))
    }
}

struct PrayerWidgetView: View {
    let entry: PrayerEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @ScaledMetric(relativeTo: .body) private var dynamicType: CGFloat = 1

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            PrayerAccessoryView(entry: entry)
        #endif
        default:
            GeometryReader { geometry in
                home(size: geometry.size)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, ZimamLocale.current)
            .containerBackground(ZimamColor.surfaceRaised, for: .widget)
            .widgetURL(AppLink.prayer.url)
        }
    }

    /// Sand in full color; on tinted and clear home screens, in StandBy at night and on the Mac
    /// desktop behind windows the system's levels, with the countdown in the accent group. Each part
    /// scales its text to fill the height it has (`WidgetFit`).
    @ViewBuilder
    private func home(size: CGSize) -> some View {
        let tone = WidgetTone(mode: mode)
        if let place = entry.place, let state = entry.state {
            let hasPlace = place.name != nil
            switch family {
            case .systemSmall:
                let countdown = PrayerCountdown.fit(height: size.height, hasPlace: hasPlace, dynamicType: dynamicType)
                PrayerCountdown(state: state, placeName: place.name, timer: countdown.timer, tone: tone)
                    .widgetTextScale(countdown.scale)
            case .systemMedium:
                let countdown = PrayerCountdown.fit(height: size.height, hasPlace: hasPlace, dynamicType: dynamicType)
                HStack(alignment: .top, spacing: ZimamSpacing.space4) {
                    PrayerCountdown(state: state, placeName: place.name, timer: countdown.timer, tone: tone)
                        .widgetTextScale(countdown.scale)
                    PrayerDayList(schedule: place.schedule, date: entry.date, next: state, withSunrise: false, tone: tone)
                        .widgetTextScale(PrayerDayList.scale(height: size.height, withSunrise: false, dynamicType: dynamicType))
                }
            default:
                let gaps = ZimamSpacing.space3 * 2
                let date = WidgetFit.textHeight([.caption], dynamicType: dynamicType)
                let countdown = PrayerCountdown.natural(timer: .display, hasPlace: hasPlace, dynamicType: dynamicType)
                let list = PrayerDayList.natural(withSunrise: true, dynamicType: dynamicType)
                let fixed = gaps + countdown.fixed + list.fixed
                let scale = WidgetFit.scale(natural: date + countdown.height + list.height + gaps, fixed: fixed,
                                            available: size.height)
                VStack(alignment: .leading, spacing: ZimamSpacing.space3) {
                    Text(DualDateFormatter(primary: SharedSettings.user()?.settings.calendar ?? .hijri,
                                           locale: ZimamLocale.current).dual(entry.date))
                        .widgetFont(.caption)
                        .foregroundStyle(tone.muted)
                        .lineLimit(1)
                    PrayerCountdown(state: state, placeName: place.name, timer: .display, tone: tone)
                    PrayerDayList(schedule: place.schedule, date: entry.date, next: state, withSunrise: true, tone: tone)
                }
                .widgetTextScale(scale)
            }
        } else {
            let gaps = ZimamSpacing.space2 * 2
            let natural = WidgetFit.textHeight([.title, .headline, .caption, .caption], dynamicType: dynamicType) + gaps
            VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                Image(systemName: "moon.stars")
                    .widgetFont(.title)
                Text("أوقات الصلاة")
                    .widgetFont(.headline)
                    .lineLimit(1)
                Text("حدّد موقعك في زمام لتظهر الصلاة القادمة.")
                    .widgetFont(.caption)
                    .lineLimit(3)
            }
            .foregroundStyle(tone.tinted(ZimamColor.sand))
            .widgetAccentable()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetTextScale(WidgetFit.scale(natural: natural, fixed: gaps, available: size.height))
        }
    }
}

/// «المتبقي على العصر» over the countdown, then the adhan's time and the place.
private struct PrayerCountdown: View {
    let state: PrayerClock.State
    let placeName: String?
    /// The countdown's style: `display` where the height allows, `title` otherwise.
    let timer: ZimamTextStyle
    let tone: WidgetTone

    var body: some View {
        let formatter = DualDateFormatter(locale: ZimamLocale.current)
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Label(state.title, systemImage: "moon.stars")
                .widgetFont(.caption)
                .lineLimit(1)
            Text(state.time, style: .timer)
                .widgetFont(timer)
                .monospacedDigit()
                .lineLimit(1)
            Text("\(state.prayer.arabicName)، \(formatter.time(state.time))")
                .widgetFont(.callout)
                .lineLimit(1)
            if let placeName {
                Text(placeName)
                    .widgetFont(.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tone.tinted(ZimamColor.sand))
        .widgetAccentable()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    /// Its height at scale 1, and the part of it (the gaps) that does not scale.
    static func natural(timer: ZimamTextStyle, hasPlace: Bool, dynamicType: CGFloat) -> (height: CGFloat, fixed: CGFloat) {
        let lines: [ZimamTextStyle] = [.caption, timer, .callout] + (hasPlace ? [.caption] : [])
        let fixed = ZimamSpacing.space1 * CGFloat(lines.count - 1)
        return (WidgetFit.textHeight(lines, dynamicType: dynamicType) + fixed, fixed)
    }

    /// The larger countdown when it fits the height at its own size or larger, the smaller one
    /// otherwise, and the scale that fills the height.
    static func fit(height: CGFloat, hasPlace: Bool, dynamicType: CGFloat) -> (timer: ZimamTextStyle, scale: CGFloat) {
        let large = natural(timer: .display, hasPlace: hasPlace, dynamicType: dynamicType)
        if large.height <= height * WidgetFit.margin {
            return (.display, WidgetFit.scale(natural: large.height, fixed: large.fixed, available: height))
        }
        let small = natural(timer: .title, hasPlace: hasPlace, dynamicType: dynamicType)
        return (.title, WidgetFit.scale(natural: small.height, fixed: small.fixed, available: height))
    }
}

/// Today's times, the next one marked; with sunrise in the large size.
private struct PrayerDayList: View {
    let schedule: PrayerSchedule
    let date: Date
    let next: PrayerClock.State
    let withSunrise: Bool
    let tone: WidgetTone

    var body: some View {
        let formatter = DualDateFormatter(locale: ZimamLocale.current)
        let times = schedule.times(on: date)
        VStack(alignment: .leading, spacing: Self.spacing(withSunrise: withSunrise)) {
            ForEach(Prayer.allCases, id: \.self) { prayer in
                if let time = times[prayer] {
                    row(prayer.arabicName, time: formatter.time(time), isNext: next.prayer == prayer && Self.sameDay(next.time, time))
                }
                if withSunrise, prayer == .fajr, let sunrise = schedule.sunrise(on: date) {
                    row("الشروق", time: formatter.time(sunrise), isNext: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ name: String, time: String, isNext: Bool) -> some View {
        HStack(spacing: ZimamSpacing.space2) {
            Text(name)
            Spacer(minLength: ZimamSpacing.space1)
            Text(time)
                .monospacedDigit()
        }
        .lineLimit(1)
        .widgetFont(isNext ? .headline : (withSunrise ? .callout : .caption))
        .foregroundStyle(isNext ? tone.tinted(ZimamColor.sand) : tone.ink)
        .padding(.horizontal, isNext ? ZimamSpacing.space2 : 0)
        .background {
            // The next prayer keeps its heavier weight in every mode; its sand-soft fill becomes a
            // faint system fill where a solid one would turn into a block of the tint.
            if isNext {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusSm)
                    .fill(tone.isFullColor ? AnyShapeStyle(ZimamColor.sandSoft) : tone.fill)
            }
        }
        .widgetAccentable(isNext)
    }

    private static func spacing(withSunrise: Bool) -> CGFloat {
        withSunrise ? ZimamSpacing.space2 : ZimamSpacing.space1
    }

    /// Its height at scale 1 (the five prayers, sunrise in the large size, the next one in the
    /// larger style), and the part of it (the gaps) that does not scale.
    static func natural(withSunrise: Bool, dynamicType: CGFloat) -> (height: CGFloat, fixed: CGFloat) {
        let others: ZimamTextStyle = withSunrise ? .callout : .caption
        let lines: [ZimamTextStyle] = [.headline] + Array(repeating: others, count: withSunrise ? 5 : 4)
        let fixed = spacing(withSunrise: withSunrise) * CGFloat(lines.count - 1)
        return (WidgetFit.textHeight(lines, dynamicType: dynamicType) + fixed, fixed)
    }

    /// The scale at which the list fills `height`.
    static func scale(height: CGFloat, withSunrise: Bool, dynamicType: CGFloat) -> CGFloat {
        let list = natural(withSunrise: withSunrise, dynamicType: dynamicType)
        return WidgetFit.scale(natural: list.height, fixed: list.fixed, available: height)
    }

    private static func sameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }
}
