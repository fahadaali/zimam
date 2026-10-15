import AppIntents
import SwiftUI
import WidgetKit
import ZimamKit

/// «تقدّم السنة»: the year as twelve month pills filling up, the share behind and the days left.
/// The Hijri year (Umm al-Qura) or the Gregorian one, chosen when editing the widget; by default
/// the user's primary calendar from settings.
struct YearProgressWidget: Widget {
    static let kind = "app.zimam.year"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: YearProgressConfiguration.self, provider: YearProgressProvider()) { entry in
            YearProgressView(entry: entry)
        }
        .configurationDisplayName("تقدّم السنة")
        .description("ما مضى من السنة الهجرية أو الميلادية وما بقي منها.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct YearProgressConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "تقدّم السنة"
    static var description = IntentDescription("اختر السنة الهجرية أو الميلادية.")

    @Parameter(title: "التقويم", default: .automatic)
    var calendar: WidgetCalendarChoice

    init() {}
}

struct YearProgressEntry: TimelineEntry {
    let date: Date
    /// The year shown.
    let kind: CalendarKind
    /// The user's primary calendar, first in the dual date.
    let primary: CalendarKind
}

/// The numbers change once a day: an entry at each of the next midnights, then a new timeline.
struct YearProgressProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> YearProgressEntry {
        YearProgressEntry(date: Date(), kind: .hijri, primary: .hijri)
    }

    func snapshot(for configuration: YearProgressConfiguration, in context: Context) async -> YearProgressEntry {
        entry(configuration, at: Date())
    }

    func timeline(for configuration: YearProgressConfiguration, in context: Context) async -> Timeline<YearProgressEntry> {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let midnights = (1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let entries = ([now] + midnights).map { entry(configuration, at: $0) }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func entry(_ configuration: YearProgressConfiguration, at date: Date) -> YearProgressEntry {
        let primary = SharedSettings.user()?.settings.calendar ?? .hijri
        return YearProgressEntry(date: date, kind: configuration.calendar.kind(default: primary), primary: primary)
    }
}

struct YearProgressView: View {
    let entry: YearProgressEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let tone = WidgetTone(mode: mode)
        let progress = YearProgress(kind: entry.kind, date: entry.date)
        let dates = DualDateFormatter(primary: entry.primary, locale: ZimamLocale.current)
        // Whole percents, rounded down: the last day of the year reads 99٪, not 100٪.
        let percent = (Double(Int(progress.fraction * 100)) / 100)
            .formatted(.percent.precision(.fractionLength(0)).locale(dates.locale))
        let left = ArabicDays.count(progress.remainingDays, locale: dates.locale)
        let isSmall = family == .systemSmall

        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            HStack(alignment: .firstTextBaseline, spacing: ZimamSpacing.space2) {
                Text(dates.yearTitle(entry.date, in: entry.kind))
                    .font(ZimamType.title)
                    .foregroundStyle(tone.ink)
                    .lineLimit(1)
                if !isSmall {
                    Text(dates.dual(entry.date))
                        .font(ZimamType.caption)
                        .foregroundStyle(tone.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(percent)
                    .font(ZimamType.title)
                    .foregroundStyle(tone.ink)
                    .lineLimit(1)
                    .widgetAccentable()
            }

            if isSmall {
                // Two rows of six.
                VStack(spacing: ZimamSpacing.space1) {
                    pillRow(Array(progress.months.prefix(6)), tone: tone, dates: dates, labels: false)
                    pillRow(Array(progress.months.dropFirst(6)), tone: tone, dates: dates, labels: false)
                }
            } else {
                pillRow(progress.months, tone: tone, dates: dates, labels: true)
            }

            HStack(spacing: ZimamSpacing.space2) {
                if !isSmall {
                    Text("مضى \(percent) من السنة")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text("بقي \(left)")
                    .lineLimit(1)
            }
            .font(ZimamType.caption)
            .foregroundStyle(tone.muted)
        }
        .zimamWidget()
        .widgetURL(AppLink.calendar.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(progress, dates: dates, percent: percent, left: left))
    }

    /// The months in a row, the first at the leading edge (the right in Arabic), each with its
    /// number under it when `labels`.
    private func pillRow(_ months: [YearProgress.Month], tone: WidgetTone, dates: DualDateFormatter, labels: Bool) -> some View {
        HStack(spacing: ZimamSpacing.space1) {
            ForEach(months) { month in
                VStack(spacing: ZimamSpacing.space1) {
                    MonthPill(month: month, tone: tone)
                        .frame(maxHeight: .infinity)
                    if labels {
                        Text(dates.number(month.number))
                            .font(ZimamType.caption)
                            .foregroundStyle(month.isCurrent ? tone.ink : tone.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// «السنة الهجرية ١٤٤٨هـ، مضى ٣٣٪، بقي ٢٣٦ يوماً، الشهر الحالي جمادى الأولى».
    private func accessibilityText(_ progress: YearProgress, dates: DualDateFormatter, percent: String, left: String) -> String {
        var parts = ["\(entry.kind == .hijri ? "السنة الهجرية" : "السنة الميلادية") \(dates.yearTitle(entry.date, in: entry.kind))",
                     "مضى \(percent)", "بقي \(left)"]
        if progress.currentMonth != nil {
            parts.append("الشهر الحالي \(dates.monthName(entry.date, in: entry.kind))")
        }
        return parts.joined(separator: "، ")
    }
}

/// A month as a pill filling from the bottom: full when gone, empty ahead, part of the current
/// one, which also has a ring.
private struct MonthPill: View {
    let month: YearProgress.Month
    let tone: WidgetTone

    var body: some View {
        Capsule()
            .fill(tone.fill)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(month.isCurrent ? tone.ink : tone.muted)
                    .scaleEffect(x: 1, y: month.filled, anchor: .bottom)
                    .widgetAccentable()
            }
            .clipShape(Capsule())
            .overlay {
                if month.isCurrent {
                    Capsule()
                        .strokeBorder(tone.ink, lineWidth: ZimamSpacing.space1 / 2)
                }
            }
    }
}
