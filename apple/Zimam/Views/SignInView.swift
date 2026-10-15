import AuthenticationServices
import SwiftUI

/// The welcome screen: the mark, the line, and the two sign-in buttons. The content is one
/// readable column, centred on iPad and Mac instead of stretching edge to edge, and scrolls
/// when it does not fit (iPhone in landscape, or large text sizes).
struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// One height for both sign-in buttons: the 44pt target, growing with the text size up to
    /// the 64pt Apple allows for its button.
    @ScaledMetric(relativeTo: .headline) private var scaledButtonHeight = ZimamSpacing.space11
    private var buttonHeight: CGFloat { min(scaledButtonHeight, ZimamSpacing.space8 * 2) }

    /// The column's width: 384pt, so the buttons keep a readable length on wide screens.
    private static let columnWidth = ZimamSpacing.space8 * 12

    /// `space4` on the iPhone, `space6` on iPad and Mac (design/README.md, «المسافات»).
    private var sideMargin: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? ZimamSpacing.space4 : ZimamSpacing.space6
        #else
        return ZimamSpacing.space6
        #endif
    }

    var body: some View {
        // The first layout fills the screen and pushes the buttons down; when it does not fit,
        // the same content scrolls instead.
        ViewThatFits(in: .vertical) {
            column(fillsHeight: true)
            ScrollView {
                column(fillsHeight: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZimamColor.surface)
    }

    private func column(fillsHeight: Bool) -> some View {
        VStack(spacing: ZimamSpacing.space6) {
            if fillsHeight { Spacer() }
            welcome
            if fillsHeight { Spacer() }
            buttons
            if let message = session.errorMessage {
                Text(message)
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.priorityHigh)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: Self.columnWidth)
        .padding(.horizontal, sideMargin)
        .padding(.vertical, ZimamSpacing.space6)
        .frame(maxWidth: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: ZimamSpacing.space4) {
            Image("ZimamMark")
                .resizable()
                .scaledToFit()
                .frame(width: ZimamSpacing.space8 * 3, height: ZimamSpacing.space8 * 3)
                .accessibilityHidden(true)
            Text("خذ زمام يومك")
                .font(ZimamType.hero)
                .lineSpacing(ZimamType.heroLineSpacing)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("مهامك بالهجري والميلادي، ومرتبطة بأوقات الصلاة.")
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Apple's button and Google's, the same height, width and corners, one above the other.
    private var buttons: some View {
        VStack(spacing: ZimamSpacing.space3) {
            SignInWithAppleButton(.continue) { request in
                session.prepare(request)
            } onCompletion: { result in
                Task { await session.complete(result) }
            }
            // Black on the light theme, white on the dark one (Apple's guidelines).
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: .infinity)
            .frame(height: buttonHeight)
            .clipShape(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            if SessionStore.isGoogleConfigured {
                GoogleButton(height: buttonHeight, isBusy: session.isSigningInWithGoogle) {
                    Task { await session.signInWithGoogle() }
                }
            }
        }
    }
}

/// «المتابعة بحساب قوقل», drawn as Google's sign-in branding guidelines require: the colour
/// G logo (Assets: GoogleLogo, from the GoogleSignIn-iOS SDK), and Google's own fill, stroke
/// and text colours for the light and dark themes. This is the one allowed exception to the
/// design tokens (CLAUDE.md): these colours are Google's, not Zimam's, so they are written
/// here. Spacing, size and the Arabic font still come from the tokens (Google's Roboto has no
/// Arabic), and the button takes the Apple button's height and corner radius.
private struct GoogleButton: View {
    var height: CGFloat
    var isBusy: Bool
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    // Google's branding colours (developers.google.com/identity/branding-guidelines).
    private var fill: Color { colorScheme == .dark ? Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x14 / 255) : .white }
    private var stroke: Color {
        colorScheme == .dark
            ? Color(red: 0x8E / 255, green: 0x91 / 255, blue: 0x8F / 255)
            : Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255)
    }
    private var text: Color {
        colorScheme == .dark
            ? Color(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE3 / 255)
            : Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ZimamRadius.radiusMd) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZimamSpacing.space3) {
                Image("GoogleLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: ZimamSpacing.space6 - ZimamSpacing.space1, height: ZimamSpacing.space6 - ZimamSpacing.space1)
                    .accessibilityHidden(true)
                if isBusy {
                    ProgressView()
                        .tint(text)
                } else {
                    Text("المتابعة بحساب قوقل")
                        .font(ZimamType.headline)
                        .foregroundStyle(text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .padding(.horizontal, ZimamSpacing.space3)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(stroke, lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("المتابعة بحساب قوقل")
    }
}
