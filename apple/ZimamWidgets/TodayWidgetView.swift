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

/// Small: how many tasks are open today, and the next one with its completion circle, scaled to
/// fill the widget's height.
private struct SmallTodayView: View {
    let entry: TodayEntry
    let tone: WidgetTone
    @ScaledMetric(relativeTo: .body) private var dynamicType: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Text("اليوم")
                    .widgetFont(.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
                Text(ArabicCount.tasks(entry.tasks.count, locale: ZimamLocale.current))
                    .widgetFont(.title)
                    .foregroundStyle(tone.ink)
                    .lineLimit(1)
                    .widgetAccentable()
                Spacer(minLength: 0)
                if let next = entry.next {
                    // The small size opens only through `widgetURL`, so the title is not a link.
                    WidgetTaskRow(task: next, tone: tone, lineLimit: 2, opensTask: false)
                } else {
                    Text("يومك لك.")
                        .widgetFont(.callout)
                        .foregroundStyle(tone.muted)
                }
            }
            .widgetTextScale(scale(height: geometry.size.height))
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    /// The scale at which the header and the next task fill the height.
    private func scale(height: CGFloat) -> CGFloat {
        let spacing = ZimamSpacing.space1 * 3
        let header = WidgetFit.textHeight([.caption, .title], dynamicType: dynamicType)
        let task = entry.next == nil
            ? WidgetFit.textHeight([.callout], dynamicType: dynamicType)
            : max(WidgetMetrics.row, WidgetFit.textHeight([.callout, .callout], dynamicType: dynamicType))
        return WidgetFit.scale(natural: header + task + spacing, fixed: spacing, available: height)
    }
}

/// Medium: the dual date and today's tasks two by two, so each circle keeps a 44pt target: as many
/// rows as fit, then all of it scaled to fill the height.
private struct MediumTodayView: View {
    let entry: TodayEntry
    let tone: WidgetTone
    @ScaledMetric(relativeTo: .body) private var dynamicType: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            layout(height: geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func layout(height: CGFloat) -> some View {
        let formatter = DualDateFormatter(primary: entry.calendar, locale: ZimamLocale.current)
        let spacing = ZimamSpacing.space1 * 2
        let header = WidgetFit.textHeight([.headline], dynamicType: dynamicType)
        let rowHeight = max(WidgetMetrics.row, WidgetFit.textHeight([.callout, .callout], dynamicType: dynamicType))
        let lines = entry.tasks.isEmpty ? 0 : max(1, Int((height - header - spacing) / rowHeight))
        let shown = Array(entry.tasks.prefix(lines * 2))
        let shownLines = (shown.count + 1) / 2
        let natural = header + spacing + (shown.isEmpty ? WidgetFit.textHeight([.callout], dynamicType: dynamicType)
                                                        : rowHeight * CGFloat(shownLines))
        let scale = WidgetFit.scale(natural: natural, fixed: spacing, available: height)
        return VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            HStack(alignment: .firstTextBaseline, spacing: ZimamSpacing.space2) {
                Text("اليوم")
                    .widgetFont(.headline)
                    .foregroundStyle(tone.ink)
                    .lineLimit(1)
                    .widgetAccentable()
                Text(formatter.dual(entry.date))
                    .widgetFont(.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if shown.isEmpty {
                WidgetMessage(text: "لا مهام اليوم. يومك لك.", tone: tone)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<shownLines, id: \.self) { line in
                        HStack(alignment: .center, spacing: ZimamSpacing.space2) {
                            cell(shown, line * 2)
                            cell(shown, line * 2 + 1)
                        }
                        .frame(height: rowHeight * scale)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .widgetTextScale(scale)
    }

    @ViewBuilder
    private func cell(_ tasks: [WidgetTask], _ index: Int) -> some View {
        if index < tasks.count {
            WidgetTaskRow(task: tasks[index], tone: tone, lineLimit: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
        }
    }
}

/// Large: today with the dual date, the next prayer-anchored task with its prayer chip, then as
/// many of the other tasks as fit, all of it scaled to fill the height.
private struct LargeTodayView: View {
    let entry: TodayEntry
    let tone: WidgetTone
    @ScaledMetric(relativeTo: .body) private var dynamicType: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            layout(height: geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func layout(height: CGFloat) -> some View {
        let formatter = DualDateFormatter(primary: entry.calendar, locale: ZimamLocale.current)
        let next = entry.nextPrayerTask
        let rest = entry.tasks.filter { $0.id != next?.id }
        let hasCard = next?.prayer != nil

        // Heights at scale 1: the header, the prayer card (chip, row and its padding), a row, and
        // the «n غيرها» line; the gaps between the sections (the last one before the spacer) do
        // not scale.
        let header = WidgetFit.textHeight([.title, .caption], dynamicType: dynamicType)
        let card = hasCard
            ? WidgetFit.textHeight([.caption], dynamicType: dynamicType) + WidgetMetrics.row + ZimamSpacing.space1 * 4
            : 0
        let more = WidgetFit.textHeight([.caption], dynamicType: dynamicType)
        let row = WidgetMetrics.row
        let gap = ZimamSpacing.space2
        let gapsAbove = gap * (hasCard ? 3 : 2)
        let room = height - header - card - gapsAbove
        let fitting = max(0, Int(room / row))
        let shownCount = rest.count > fitting ? max(0, Int((room - more - gap) / row)) : rest.count
        let shown = Array(rest.prefix(shownCount))
        let hidden = rest.count - shown.count
        let fixed = gapsAbove + (hidden > 0 ? gap : 0)
        let list = entry.tasks.isEmpty
            ? WidgetFit.textHeight([.callout], dynamicType: dynamicType)
            : row * CGFloat(shown.count) + (hidden > 0 ? more : 0)
        let scale = WidgetFit.scale(natural: header + card + list + fixed, fixed: fixed, available: height)

        return VStack(alignment: .leading, spacing: gap) {
            VStack(alignment: .leading, spacing: 0) {
                Text("اليوم")
                    .widgetFont(.title)
                    .foregroundStyle(tone.ink)
                    .lineLimit(1)
                    .widgetAccentable()
                Text(formatter.dual(entry.date, withYear: true))
                    .widgetFont(.caption)
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
                        .widgetFont(.caption)
                        .foregroundStyle(tone.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .widgetTextScale(scale)
    }
}

/// A simplified task row: the completion circle (an App Intent button, so it works without
/// opening the app) and the title, which opens the task where the size allows links. The row and
/// its circle grow with the text when the layout scales it (`widgetTextScale`).
struct WidgetTaskRow: View {
    let task: WidgetTask
    let tone: WidgetTone
    var lineLimit = 1
    var opensTask = true
    @Environment(\.widgetTextScale) private var scale

    var body: some View {
        let side = ZimamSpacing.space11 * max(scale, 1)
        HStack(spacing: ZimamSpacing.space1) {
            Button(intent: CompleteTaskIntent(task: TaskEntity(id: task.id, title: task.title))) {
                Image(systemName: "circle")
                    .widgetFont(.title)
                    .foregroundStyle(tone.strong)
                    .frame(width: side, height: side)
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
        .frame(minHeight: side)
    }

    private var title: some View {
        Text(task.title)
            .widgetFont(.callout)
            .foregroundStyle(tone.ink)
            .lineLimit(lineLimit)
            .widgetTextDirection(of: task.title)
            .contentShape(Rectangle())
    }
}

/// One quiet sentence: signed out, or nothing due today.
private struct WidgetMessage: View {
    let text: String
    let tone: WidgetTone

    var body: some View {
        Text(text)
            .widgetFont(.callout)
            .foregroundStyle(tone.muted)
    }
}
