import SwiftUI

// Each text in its own direction. The widgets are laid out right to left (Arabic), but a task's
// title is whatever the user typed: an Arabic title starts from the right and an English one
// from the left, whatever the layout around it.
//
// Where the system draws the text itself (the line above the watch's clock, the curve of a
// corner), the app's layout direction is ignored and the line takes the watch's language: on a
// watch in English an Arabic line read as left to right, with a symbol or the time on the wrong
// side. There a mark at the start of the text sets its direction.
//
// Shared by the home-screen widgets (ZimamWidgets) and the accessory widgets (Glance).

nonisolated enum WidgetTextDirection {
    /// Whether `text` reads right to left: its first letter is Arabic (or Hebrew, Syriac, Thaana…).
    /// Text without a letter (numbers alone) follows the Arabic layout.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                return false
            }
        }
        return true
    }

    static func layoutDirection(of text: String) -> LayoutDirection {
        isRightToLeft(text) ? .rightToLeft : .leftToRight
    }

    /// `text` with a mark at its start that sets its direction (RLM or LRM), for text the system
    /// draws in the watch's language.
    static func marked(_ text: String) -> String {
        (isRightToLeft(text) ? "\u{200F}" : "\u{200E}") + text
    }
}

extension View {
    /// A task's title in its own direction, across the width it is given: an Arabic title from the
    /// right, an English one from the left.
    func widgetTextDirection(of text: String) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, WidgetTextDirection.layoutDirection(of: text))
    }
}
