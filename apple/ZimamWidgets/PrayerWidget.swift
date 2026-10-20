import SwiftUI
import WidgetKit
import ZimamKit

/// «الصلاة القادمة»: the time left until the next prayer, and for half an hour after an adhan the
/// time since it, then the next prayer. Small: the countdown. Medium: with today's times. Large:
/// with today's times, sunrise and the dual date. On the iPhone Lock Screen too, with the watch
/// complications' views (Glance/PrayerGlanceViews.swift).
struct PrayerWidget: Widget {
    static let kind = "app.zimam.prayer"

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

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            PrayerAccessoryView(entry: entry)
        #endif
        default:
            home
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, ZimamLocale.current)
                .containerBackground(ZimamColor.surfaceRaised, for: .widget)
                .widgetURL(AppLink.prayer.url)
        }
    }

    @ViewBuilder
    private var home: some View {
        if let place = entry.place, let state = entry.state {
            switch family {
            case .systemSmall:
                PrayerCountdown(state: state, placeName: place.name, large: false)
            case .systemMedium:
                HStack(alignment: .top, spacing: ZimamSpacing.space4) {
                    PrayerCountdown(state: state, placeName: place.name, large: false)
                    PrayerDayList(schedule: place.schedule, date: entry.date, next: state, withSunrise: false)
                }
            default:
                VStack(alignment: .leading, spacing: ZimamSpacing.space3) {
                    Text(DualDateFormatter(primary: SharedSettings.user()?.settings.calendar ?? .hijri,
                                           locale: ZimamLocale.current).dual(entry.date))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                    PrayerCountdown(state: state, placeName: place.name, large: true)
                    PrayerDayList(schedule: place.schedule, date: entry.date, next: state, withSunrise: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                Image(systemName: "moon.stars")
                    .font(ZimamType.title)
                Text("أوقات الصلاة")
                    .font(ZimamType.headline)
                Text("حدّد موقعك في زمام لتظهر الصلاة القادمة.")
                    .font(ZimamType.caption)
            }
            .foregroundStyle(ZimamColor.sand)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// «المتبقي على العصر» over the countdown, then the adhan's time and the place.
private struct PrayerCountdown: View {
    let state: PrayerClock.State
    let placeName: String?
    let large: Bool

    var body: some View {
        let formatter = DualDateFormatter(locale: ZimamLocale.current)
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Label(prayerTitle, systemImage: "moon.stars")
                .font(ZimamType.caption)
                .lineLimit(1)
            Text(state.time, style: .timer)
                .font(large ? ZimamType.display : ZimamType.title)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(state.prayer.arabicName)، \(formatter.time(state.time))")
                .font(ZimamType.callout)
                .lineLimit(1)
            if let placeName {
                Text(placeName)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(ZimamColor.sand)
        .frame(maxWidth: .infinity, maxHeight: large ? nil : .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var prayerTitle: String {
        switch state {
        case .since(let prayer, _): "مضى على أذان \(prayer.arabicName)"
        case .until(let prayer, _): "المتبقي على \(prayer.arabicName)"
        }
    }
}

/// Today's times, the next one marked; with sunrise in the large size.
private struct PrayerDayList: View {
    let schedule: PrayerSchedule
    let date: Date
    let next: PrayerClock.State
    let withSunrise: Bool

    var body: some View {
        let formatter = DualDateFormatter(locale: ZimamLocale.current)
        let times = schedule.times(on: date)
        VStack(alignment: .leading, spacing: withSunrise ? ZimamSpacing.space2 : ZimamSpacing.space1) {
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
        .font(isNext ? ZimamType.headline : (withSunrise ? ZimamType.callout : ZimamType.caption))
        .foregroundStyle(isNext ? ZimamColor.sand : ZimamColor.ink)
        .padding(.horizontal, isNext ? ZimamSpacing.space2 : 0)
        .background {
            if isNext {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusSm).fill(ZimamColor.sandSoft)
            }
        }
    }

    private static func sameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }
}
