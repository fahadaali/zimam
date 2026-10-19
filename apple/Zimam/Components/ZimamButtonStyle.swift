import SwiftUI

/// primary: one per screen (brand fill); secondary: bordered; quiet: brand text. See design/components/Button.
struct ZimamButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, quiet }

    var variant: Variant = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ZimamType.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.vertical, ZimamSpacing.space2)
            .padding(.horizontal, ZimamSpacing.space4)
            .frame(minHeight: ZimamSpacing.space11)
            .background(background, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .overlay {
                if variant == .secondary && isEnabled {
                    RoundedRectangle(cornerRadius: ZimamRadius.radiusMd).stroke(ZimamColor.lineStrong)
                }
            }
            .opacity(configuration.isPressed ? ZimamOpacity.pressed : 1)
    }

    private var foreground: Color {
        guard isEnabled else { return ZimamColor.inkFaint }
        switch variant {
        case .primary: return ZimamColor.onBrand
        case .secondary: return ZimamColor.ink
        case .quiet: return ZimamColor.brand
        }
    }

    private var background: Color {
        guard isEnabled else { return ZimamColor.surfaceSunken }
        switch variant {
        case .primary: return ZimamColor.brand
        case .secondary: return ZimamColor.surfaceRaised
        case .quiet: return .clear
        }
    }
}

extension ButtonStyle where Self == ZimamButtonStyle {
    static var zimamPrimary: ZimamButtonStyle { ZimamButtonStyle(variant: .primary) }
    static var zimamSecondary: ZimamButtonStyle { ZimamButtonStyle(variant: .secondary) }
    static var zimamQuiet: ZimamButtonStyle { ZimamButtonStyle(variant: .quiet) }
}
