import SwiftUI
import WidgetKit
import ZimamKit

// MARK: Root

/// The root modifiers of every widget in the family: Arabic, right to left, Thmanyah, and the
/// card surface as the removable container background.
struct WidgetFrame: ViewModifier {
    var padding: CGFloat? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, ZimamLocale.current)
            .font(ZimamType.body)
            .foregroundStyle(ZimamColor.ink)
            .containerBackground(for: .widget) { ZimamColor.surfaceRaised }
    }
}

extension View {
    func zimamWidget(padding: CGFloat? = nil) -> some View {
        modifier(WidgetFrame(padding: padding))
    }
}
