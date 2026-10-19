import SwiftUI

/// The completion circle at the leading edge of a task row (design/components/TaskRow).
/// The circle fills with a symbol transition, and the success haptic plays on the same tap,
/// only when the person completes the task: not when undoing it, and not when sync changes it.
/// The whole 44pt frame takes the tap, not just the drawn circle.
struct CompletionCircle: View {
    let isDone: Bool
    var font: Font = ZimamType.title
    var alignment: Alignment = .center
    let action: () -> Void

    /// Counts the person's completions; each change plays the haptic.
    @State private var completions = 0

    var body: some View {
        Button {
            let completing = !isDone
            action()
            if completing { completions += 1 }
        } label: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(font)
                .foregroundStyle(isDone ? ZimamColor.brand : ZimamColor.lineStrong)
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: ZimamSpacing.space11, minHeight: ZimamSpacing.space11, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: completions)
        .accessibilityLabel(isDone ? "إلغاء الإنجاز" : "إنجاز")
    }
}
