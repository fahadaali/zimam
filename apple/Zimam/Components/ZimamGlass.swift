import SwiftUI

// Liquid Glass for Zimam's control layer on iOS 26 and macOS 26, with the earlier look as the
// fallback (the app still runs on iOS 18 and macOS 15). Glass belongs to controls that float
// over the content: the add button, the toolbar, the tab bar and the sidebar. Never to task
// rows, cards or chips: «الهدوء قبل الزينة» (design/README.md). Tints come from the tokens only.

extension View {
    /// A glass surface in `shape` on iOS and macOS 26; a flat `fallback` fill before.
    /// Apply it after the layout and appearance modifiers.
    @ViewBuilder
    func zimamGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: Color = ZimamColor.surfaceRaised
    ) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            background(fallback, in: shape)
        }
    }

    /// The floating «إضافة مهمة» button: prominent brand glass on 26, the brand circle before.
    @ViewBuilder
    func zimamFloatingActionStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(ZimamColor.brand)
        } else {
            buttonStyle(FloatingActionFallbackStyle())
        }
    }

    /// The one primary action of a toolbar («إنجاز»): brand glass on 26, the system look before.
    @ViewBuilder
    func zimamProminentToolbarAction() -> some View {
        if #available(iOS 26, macOS 26, *) {
            buttonStyle(.glassProminent).tint(ZimamColor.brand)
        } else {
            self
        }
    }

    /// The iPhone tab bar shrinks while the list scrolls down (iOS 26), so the tasks get the room.
    @ViewBuilder
    func zimamTabBarMinimizes() -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// The sidebar's background: the system glass column on 26, the sunken surface before.
    @ViewBuilder
    func zimamSidebarBackground() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
        } else {
            scrollContentBackground(.hidden)
                .background(ZimamColor.surfaceSunken)
        }
    }
}

/// The add button before iOS 26 and macOS 26: a brand circle, as in design/components/Button.
private struct FloatingActionFallbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ZimamColor.onBrand)
            .padding(ZimamSpacing.space1)
            .background(ZimamColor.brand, in: Circle())
            .opacity(configuration.isPressed ? ZimamOpacity.pressed : 1)
    }
}
