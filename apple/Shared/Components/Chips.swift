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

/// A prayer-anchored time. Sand is reserved for prayer times. See design/components/PrayerChip.
struct PrayerChip: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "moon.stars")
            .labelStyle(ChipLabelStyle())
            .font(ZimamType.caption)
            .foregroundStyle(ZimamColor.sand)
            .padding(.horizontal, ZimamSpacing.space2)
            .padding(.vertical, ZimamSpacing.space1 / 2)
            .background(ZimamColor.sandSoft, in: Capsule())
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
                .accessibilityLabel(label)
        }
    }

    private var color: Color {
        switch priority {
        case .high: ZimamColor.priorityHigh
        case .medium: ZimamColor.priorityMedium
        default: ZimamColor.priorityLow
        }
    }

    private var label: String {
        switch priority {
        case .high: "أولوية عالية"
        case .medium: "أولوية متوسطة"
        default: "أولوية منخفضة"
        }
    }
}
