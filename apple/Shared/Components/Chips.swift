import SwiftUI
import ZimamKit

/// Hijri and Gregorian together, or one word for nearby days. See design/components/DateChip.
struct DateChip: View {
    let text: String
    var overdue = false

    var body: some View {
        Text(text)
            .font(ZimamType.caption)
            .foregroundStyle(overdue ? ZimamColor.priorityHigh : ZimamColor.inkMuted)
            .padding(.horizontal, ZimamSpacing.space2)
            .padding(.vertical, ZimamSpacing.space1 / 2)
            .background(ZimamColor.surfaceSunken, in: Capsule())
            .accessibilityLabel(overdue ? "\(text)، متأخرة" : text)
    }
}

/// A task's clock time on its day: «٣:٠٠ م». Quiet like the date beside it. See design/components/TaskRow.
struct TimeChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ZimamType.caption)
            .foregroundStyle(ZimamColor.inkMuted)
            .padding(.horizontal, ZimamSpacing.space2)
            .padding(.vertical, ZimamSpacing.space1 / 2)
            .background(ZimamColor.surfaceSunken, in: Capsule())
    }
}

/// A prayer-anchored time. Sand is reserved for prayer times. See design/components/PrayerChip.
/// In a task row `text` is the time the prayer gives on the task's day («٢:٥٠ م») and `phrase`
/// the anchor («قبل العصر بـ١٠ د»), which VoiceOver reads after it.
struct PrayerChip: View {
    let text: String
    var phrase: String?

    var body: some View {
        Label(text, systemImage: "moon.stars")
            .labelStyle(ChipLabelStyle())
            .font(ZimamType.caption)
            .foregroundStyle(ZimamColor.sand)
            .padding(.horizontal, ZimamSpacing.space2)
            .padding(.vertical, ZimamSpacing.space1 / 2)
            .background(ZimamColor.sandSoft, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(phrase.map { "\(text)، \($0)" } ?? text)
    }
}

/// A saved place to pick («البيت»), as in Apple's Reminders. Neutral with a strong border, since
/// it is tappable; the chosen one in brand, since picking is an action. A 44pt target.
/// See design/components/PlaceChip.
struct PlaceChip: View {
    let name: String
    var isSelected = false

    var body: some View {
        Label(name, systemImage: isSelected ? "mappin.circle.fill" : "mappin")
            .labelStyle(ChipLabelStyle())
            .font(ZimamType.callout)
            .lineLimit(1)
            .foregroundStyle(isSelected ? ZimamColor.onBrand : ZimamColor.ink)
            .padding(.horizontal, ZimamSpacing.space3)
            .frame(minHeight: ZimamSpacing.space11)
            .background(isSelected ? ZimamColor.brand : ZimamColor.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? ZimamColor.brand : ZimamColor.lineStrong))
            .contentShape(Capsule())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: ZimamSpacing.space1) {
            configuration.icon
            configuration.title
        }
    }
}

/// The priority flag; never color alone, so it carries a spoken label.
struct PriorityFlag: View {
    let priority: TaskPriority

    var body: some View {
        if priority != .none {
            Image(systemName: "flag.fill")
                .font(ZimamType.caption)
                .foregroundStyle(color)
                .accessibilityLabel(priority.spokenLabel ?? "")
        }
    }

    private var color: Color {
        switch priority {
        case .high: ZimamColor.priorityHigh
        case .medium: ZimamColor.priorityMedium
        default: ZimamColor.priorityLow
        }
    }
}

extension TaskPriority {
    /// The flag's spoken text, also read on a kanban card; nil for no priority.
    var spokenLabel: String? {
        switch self {
        case .none: nil
        case .high: "أولوية عالية"
        case .medium: "أولوية متوسطة"
        case .low: "أولوية منخفضة"
        }
    }
}
