import AppIntents
import SwiftUI
import WidgetKit
import ZimamKit

/// The widget's root: the right layout for the size, in Arabic and right to left,
/// on `surfaceRaised`. The system draws the widget's own rounded corners; cards inside use `radiusLg`.
struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if !entry.isSignedIn {
                WidgetMessage(text: "سجّل الدخول في زمام لتظهر مهامك هنا.")
            } else {
                switch family {
                case .systemSmall:
                    SmallTodayView(entry: entry)
                case .systemMedium:
                    MediumTodayView(entry: entry)
                default:
                    LargeTodayView(entry: entry)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, ZimamLocale.current)
        .font(ZimamType.body)
        .foregroundStyle(ZimamColor.ink)
        .containerBackground(ZimamColor.surfaceRaised, for: .widget)
    }
}

/// Small: how many tasks are open today, and the next one with its completion circle.
private struct SmallTodayView: View {
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Text("اليوم")
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            Text(ArabicCount.tasks(entry.tasks.count, locale: ZimamLocale.current))
                .font(ZimamType.title)
                .foregroundStyle(ZimamColor.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let next = entry.tasks.first {
                WidgetTaskRow(task: next, lineLimit: 2)
            } else {
                Text("يومك لك.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
    }
}

/// Medium: the dual date and up to four tasks, two by two so each circle keeps a 44pt target.
private struct MediumTodayView: View {
    let entry: TodayEntry

    var body: some View {
        let formatter = DualDateFormatter(primary: entry.calendar, locale: ZimamLocale.current)
        let shown = Array(entry.tasks.prefix(4))
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            HStack(alignment: .firstTextBaseline, spacing: ZimamSpacing.space2) {
                Text("اليوم")
                    .font(ZimamType.headline)
                    .foregroundStyle(ZimamColor.ink)
                Text(formatter.dual(entry.date))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if shown.isEmpty {
                WidgetMessage(text: "لا مهام اليوم. يومك لك.")
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
            WidgetTaskRow(task: tasks[index], lineLimit: 2)
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
                    .foregroundStyle(ZimamColor.ink)
                Text(formatter.dual(entry.date, withYear: true))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .lineLimit(1)
            }

            if let next, let prayer = next.prayer {
                VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                    PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: next.prayerOffset, locale: formatter.locale))
                    WidgetTaskRow(task: next)
                }
                .padding(.horizontal, ZimamSpacing.space2)
                .padding(.vertical, ZimamSpacing.space1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ZimamColor.surfaceSunken, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
            }

            if entry.tasks.isEmpty {
                WidgetMessage(text: "لا مهام اليوم. يومك لك.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { task in
                        WidgetTaskRow(task: task)
                    }
                }
                if hidden > 0 {
                    Text("\(ArabicCount.tasks(hidden, locale: formatter.locale)) غيرها")
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A simplified task row: the completion circle (an App Intent button, so it works without
/// opening the app) and the title.
struct WidgetTaskRow: View {
    let task: WidgetTask
    var lineLimit = 1

    var body: some View {
        HStack(spacing: ZimamSpacing.space1) {
            Button(intent: CompleteTaskIntent(task: TaskEntity(id: task.id, title: task.title))) {
                Image(systemName: "circle")
                    .font(ZimamType.title)
                    .foregroundStyle(ZimamColor.lineStrong)
                    .frame(width: ZimamSpacing.space11, height: ZimamSpacing.space11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إنجاز \(task.title)")

            Text(task.title)
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.ink)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: ZimamSpacing.space11)
    }
}

/// One quiet sentence: signed out, or nothing due today.
private struct WidgetMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ZimamType.callout)
            .foregroundStyle(ZimamColor.inkMuted)
    }
}
