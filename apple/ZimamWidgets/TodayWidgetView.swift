import AppIntents
import SwiftUI
import WidgetKit
import ZimamKit

/// The widget's root: the right layout for the size, in Arabic and right to left,
/// on `surfaceRaised`. The system draws the widget's own rounded corners; cards inside use `radiusLg`.
/// Colors follow the rendering mode (`WidgetTone`): the tokens in full color, the system's levels
/// on tinted and clear home screens, in StandBy at night and on the Mac desktop behind windows.
struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let tone = WidgetTone(mode: mode)
        Group {
            if !entry.isSignedIn {
                WidgetMessage(text: "سجّل الدخول في زمام لتظهر مهامك هنا.", tone: tone)
            } else {
                switch family {
                case .systemSmall:
                    SmallTodayView(entry: entry, tone: tone)
                case .systemMedium:
                    MediumTodayView(entry: entry, tone: tone)
                default:
                    LargeTodayView(entry: entry, tone: tone)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, ZimamLocale.current)
        .font(ZimamType.body)
        .foregroundStyle(ZimamColor.ink)
        .containerBackground(ZimamColor.surfaceRaised, for: .widget)
        // Outside a task's title (which opens the task), a tap opens «اليوم», not the last screen.
        .widgetURL(AppLink.today.url)
    }
}

/// Small: how many tasks are open today, and the next one with its completion circle.
private struct SmallTodayView: View {
    let entry: TodayEntry
    let tone: WidgetTone

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Text("اليوم")
                .font(ZimamType.caption)
                .foregroundStyle(tone.muted)
            Text(ArabicCount.tasks(entry.tasks.count, locale: ZimamLocale.current))
                .font(ZimamType.title)
                .foregroundStyle(tone.ink)
                .lineLimit(1)
                .widgetAccentable()
            Spacer(minLength: 0)
            if let next = entry.next {
                // The small size opens only through `widgetURL`, so the title is not a link.
                WidgetTaskRow(task: next, tone: tone, lineLimit: 2, opensTask: false)
            } else {
                Text("يومك لك.")
                    .font(ZimamType.callout)
                    .foregroundStyle(tone.muted)
            }
        }
    }
}

/// Medium: the dual date and up to four tasks, two by two so each circle keeps a 44pt target.
private struct MediumTodayView: View {
    let entry: TodayEntry
    let tone: WidgetTone

    var body: some View {
        let formatter = DualDateFormatter(primary: entry.calendar, locale: ZimamLocale.current)
        let shown = Array(entry.tasks.prefix(4))
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            HStack(alignment: .firstTextBaseline, spacing: ZimamSpacing.space2) {
                Text("اليوم")
                    .font(ZimamType.headline)
                    .foregroundStyle(tone.ink)
                    .widgetAccentable()
                Text(formatter.dual(entry.date))
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if shown.isEmpty {
                WidgetMessage(text: "لا مهام اليوم. يومك لك.", tone: tone)
            } else {
                HStack(alignment: .top, spacing: ZimamSpacing.space2) {
                    cell(shown, 0)
                    cell(shown, 1)
                }
                HStack(alignment: .top, spacing: ZimamSpacing.space2) {
                    cell(shown, 2)
                    cell(shown, 3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func cell(_ tasks: [WidgetTask], _ index: Int) -> some View {
        if index < tasks.count {
            WidgetTaskRow(task: tasks[index], tone: tone, lineLimit: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: ZimamSpacing.space11)
        }
    }
}

/// Large: today with the dual date, the next prayer-anchored task with its prayer chip,
/// then the other tasks.
private struct LargeTodayView: View {
    let entry: TodayEntry
    let tone: WidgetTone

    var body: some View {
        let formatter = DualDateFormatter(primary: entry.calendar, locale: ZimamLocale.current)
        let next = entry.nextPrayerTask
        let rest = entry.tasks.filter { $0.id != next?.id }
        let shown = Array(rest.prefix(next == nil ? 5 : 3))
        let hidden = rest.count - shown.count
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            VStack(alignment: .leading, spacing: 0) {
                Text("اليوم")
                    .font(ZimamType.title)
                    .foregroundStyle(tone.ink)
                    .widgetAccentable()
                Text(formatter.dual(entry.date, withYear: true))
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
            }

            if let next, let prayer = next.prayer {
                VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                    let phrase = PrayerPhrase.text(prayer, offsetMinutes: next.prayerOffset, locale: formatter.locale)
                    // «بعد العصر بـ٢٠ د، ٣:٤٥ م», as on the Lock Screen; the phrase alone without a place.
                    WidgetPrayerChip(text: entry.nextPrayerTime.map { "\(phrase)، \(formatter.time($0))" } ?? phrase,
                                     tone: tone)
                    WidgetTaskRow(task: next, tone: tone)
                }
                .padding(.horizontal, ZimamSpacing.space2)
                .padding(.vertical, ZimamSpacing.space1)
                .frame(maxWidth: .infinity, alignment: .leading)
                // surfaceSunken in full color; a faint system fill otherwise, not a block of the tint.
                .background(tone.fill, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
            }

            if entry.tasks.isEmpty {
                WidgetMessage(text: "لا مهام اليوم. يومك لك.", tone: tone)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { task in
                        WidgetTaskRow(task: task, tone: tone)
                    }
                }
                if hidden > 0 {
                    Text("\(ArabicCount.tasks(hidden, locale: formatter.locale)) غيرها")
                        .font(ZimamType.caption)
                        .foregroundStyle(tone.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A simplified task row: the completion circle (an App Intent button, so it works without
/// opening the app) and the title, which opens the task where the size allows links.
struct WidgetTaskRow: View {
    let task: WidgetTask
    let tone: WidgetTone
    var lineLimit = 1
    var opensTask = true

    var body: some View {
        HStack(spacing: ZimamSpacing.space1) {
            Button(intent: CompleteTaskIntent(task: TaskEntity(id: task.id, title: task.title))) {
                Image(systemName: "circle")
                    .font(ZimamType.title)
                    .foregroundStyle(tone.strong)
                    .frame(width: ZimamSpacing.space11, height: ZimamSpacing.space11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إنجاز \(task.title)")

            if opensTask {
                Link(destination: AppLink.task(task.id).url) { title }
            } else {
                title
            }
        }
        .frame(minHeight: ZimamSpacing.space11)
    }

    private var title: some View {
        Text(task.title)
            .font(ZimamType.callout)
            .foregroundStyle(tone.ink)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// One quiet sentence: signed out, or nothing due today.
private struct WidgetMessage: View {
    let text: String
    let tone: WidgetTone

    var body: some View {
        Text(text)
            .font(ZimamType.callout)
            .foregroundStyle(tone.muted)
    }
}
