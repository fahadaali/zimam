import AppIntents
import SwiftUI
import WidgetKit
import ZimamKit

/// The completion circle: an App Intent button, so the task is done without opening the app.
/// The circle takes the task's priority color; the target is 44pt, and grows with the row when
/// the widget's layout scales its text (`widgetTextScale`).
struct WidgetCompleteButton: View {
    let item: WidgetItem
    let tone: WidgetTone
    @Environment(\.widgetTextScale) private var scale

    var body: some View {
        Button(intent: CompleteTaskIntent(task: TaskEntity(id: item.id, title: item.title))) {
            Image(systemName: "circle")
                .widgetFont(.headline)
                .foregroundStyle(item.priority == .none ? tone.strong : tone.priority(item.priority))
                .widgetAccentable(item.priority != .none)
                .frame(width: WidgetMetrics.row * max(scale, 1), height: WidgetMetrics.row * max(scale, 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("إنجاز \(item.title)")
    }
}

/// A number in a capsule: the count of a quadrant or of a month.
struct WidgetCountBadge: View {
    let count: Int
    /// Solid color behind the number; nil for a quiet badge on `surfaceSunken`.
    var color: Color?
    let tone: WidgetTone
    let locale: Locale

    var body: some View {
        Text(count.formatted(.number.locale(locale)))
            .widgetFont(.caption)
            .foregroundStyle(color == nil ? tone.ink : tone.onSolid)
            .padding(.horizontal, ZimamSpacing.space2)
            .frame(minWidth: ZimamSpacing.space6)
            .background {
                if tone.isFullColor {
                    Capsule().fill(color ?? ZimamColor.surfaceSunken)
                } else {
                    Capsule().strokeBorder(.secondary)
                }
            }
            .widgetAccentable(color != nil)
            .accessibilityLabel(ArabicCount.tasks(count, locale: locale))
    }
}

/// A prayer-anchored time in a widget: the look of the app's `PrayerChip` (the moon and the words
/// in sand on sand-soft) in full color, with its text at the widget's scale (`widgetFont`). In the
/// tinted and vibrant modes a solid fill would turn into a block of the tint, so the same moon and
/// words sit in an outlined capsule in the system's levels.
struct WidgetPrayerChip: View {
    let text: String
    let tone: WidgetTone

    var body: some View {
        HStack(spacing: ZimamSpacing.space1) {
            Image(systemName: "moon.stars")
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
        }
        .widgetFont(.caption)
        .foregroundStyle(tone.prayer)
        .padding(.horizontal, ZimamSpacing.space2)
        .padding(.vertical, ZimamSpacing.space1 / 2)
        .background {
            if tone.isFullColor {
                Capsule().fill(ZimamColor.sandSoft)
            } else {
                Capsule().strokeBorder(.secondary)
            }
        }
        .widgetAccentable(!tone.isFullColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// «+٣»: tasks of a day that did not fit.
struct WidgetMoreLabel: View {
    let count: Int
    let tone: WidgetTone
    let locale: Locale

    var body: some View {
        Text("+\(count.formatted(.number.locale(locale)))")
            .widgetFont(.caption)
            .foregroundStyle(tone.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, ZimamSpacing.space1)
            .accessibilityLabel("\(ArabicCount.tasks(count, locale: locale)) غيرها")
    }
}

/// One quiet sentence: signed out, or nothing to show.
struct WidgetNote: View {
    let text: String
    let tone: WidgetTone

    var body: some View {
        Text(text)
            .widgetFont(.callout)
            .foregroundStyle(tone.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
