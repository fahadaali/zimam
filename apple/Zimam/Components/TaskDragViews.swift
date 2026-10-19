import SwiftUI

/// What follows the finger while a task is dragged: its title on a raised card, lifted by
/// `shadow-lift` (design/README.md «الحالات والحركة»). The padding leaves room for the shadow,
/// which would otherwise be cut off at the edges of the preview.
struct TaskDragPreview: View {
    let title: String

    var body: some View {
        Text(title)
            .font(ZimamType.body)
            .foregroundStyle(ZimamColor.ink)
            .lineLimit(2)
            .padding(.horizontal, ZimamSpacing.space4)
            .padding(.vertical, ZimamSpacing.space3)
            .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .shadow(color: ZimamShadow.liftColor, radius: ZimamShadow.liftRadius,
                    x: ZimamShadow.liftX, y: ZimamShadow.liftY)
            .padding(ZimamShadow.liftRadius)
            .padding(.bottom, ZimamShadow.liftY)
    }
}

extension View {
    /// Accepts dragged tasks, with a light snap haptic when a drop lands: on the same frame as
    /// the card settles, and only for a drop `action` accepts.
    func taskDropDestination(
        _ action: @escaping ([TaskDragItem]) -> Bool, isTargeted: @escaping (Bool) -> Void
    ) -> some View {
        modifier(TaskDropDestination(action: action, isTargeted: isTargeted))
    }
}

private struct TaskDropDestination: ViewModifier {
    let action: ([TaskDragItem]) -> Bool
    let isTargeted: (Bool) -> Void

    @State private var landed = 0

    func body(content: Content) -> some View {
        content
            .dropDestination(for: TaskDragItem.self) { items, _ in
                let accepted = action(items)
                if accepted { landed += 1 }
                return accepted
            } isTargeted: { targeted in
                isTargeted(targeted)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: landed)
    }
}
