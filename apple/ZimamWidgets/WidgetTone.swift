import SwiftUI
import WidgetKit
import ZimamKit

// MARK: Rendering modes

/// Colors by rendering mode. In full color (the home screen, StandBy by day, the Mac desktop in
/// front) the Zimam tokens. Tinted home screens draw widgets "accented" and StandBy at night and
/// the Mac desktop behind windows draw them "vibrant": colors become one tone, so hierarchy comes
/// from the system's levels, solid fills become faint ones (a solid fill would turn into a block of
/// the tint), and what carries meaning joins the accent group (`widgetAccentable`).
struct WidgetTone {
    let mode: WidgetRenderingMode

    var isFullColor: Bool { mode == .fullColor }

    var ink: AnyShapeStyle { style(ZimamColor.ink, else: .primary) }
    var muted: AnyShapeStyle { style(ZimamColor.inkMuted, else: .secondary) }
    /// Padding days of a month grid.
    var faint: AnyShapeStyle { style(ZimamColor.inkFaint, else: .tertiary) }
    /// Chips, cells and tracks.
    var fill: AnyShapeStyle { style(ZimamColor.surfaceSunken, else: .quaternary) }
    /// Rings and the completion circle of a task without priority.
    var strong: AnyShapeStyle { style(ZimamColor.lineStrong, else: .secondary) }
    /// Prayer times only.
    var prayer: AnyShapeStyle { style(ZimamColor.sand, else: .secondary) }
    /// Late: overdue, or today's time already gone.
    var late: AnyShapeStyle { style(ZimamColor.priorityHigh, else: .primary) }
    /// Text on a solid colored badge or on today's filled circle.
    var onSolid: AnyShapeStyle { style(ZimamColor.surfaceRaised, else: .primary) }

    func priority(_ priority: TaskPriority) -> AnyShapeStyle {
        style(Self.color(priority), else: .primary)
    }

    /// Any token in full color, the system's level otherwise.
    func tinted(_ color: Color, else fallback: HierarchicalShapeStyle = .primary) -> AnyShapeStyle {
        style(color, else: fallback)
    }

    /// A span bar's fill: its priority color, light enough for `ink` text on it in both themes.
    func barFill(_ priority: TaskPriority) -> AnyShapeStyle {
        isFullColor ? AnyShapeStyle(Self.color(priority).opacity(WidgetMetrics.barOpacity)) : AnyShapeStyle(.quaternary)
    }

    /// The priority tokens; a task without priority gets the neutral border color.
    static func color(_ priority: TaskPriority) -> Color {
        switch priority {
        case .high: ZimamColor.priorityHigh
        case .medium: ZimamColor.priorityMedium
        case .low: ZimamColor.priorityLow
        case .none: ZimamColor.lineStrong
        }
    }

    private func style(_ color: Color, else fallback: HierarchicalShapeStyle) -> AnyShapeStyle {
        isFullColor ? AnyShapeStyle(color) : AnyShapeStyle(fallback)
    }
}

/// Sizes the widgets derive from the spacing tokens.
enum WidgetMetrics {
    /// The colored edge of a task chip.
    static let stripe = ZimamSpacing.space1 / 2
    /// Gap between chips and lanes.
    static let gap = ZimamSpacing.space1 / 2
    /// A one-line chip lane (caption text).
    static let lane = ZimamSpacing.space4 + ZimamSpacing.space1
    /// A two-line chip lane (time over title).
    static let tallLane = ZimamSpacing.space8 + ZimamSpacing.space1
    /// The tint behind a span bar. Light enough that `ink` on it keeps 4.5:1 in both themes.
    static let barOpacity = 0.22
    /// A task row with its completion circle: the 44pt touch target.
    static let row = ZimamSpacing.space11
}
