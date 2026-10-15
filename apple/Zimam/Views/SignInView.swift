import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: ZimamSpacing.space6) {
            Spacer()
            Image("ZimamMark")
                .resizable()
                .scaledToFit()
                .frame(width: ZimamSpacing.space8 * 3, height: ZimamSpacing.space8 * 3)
                .accessibilityHidden(true)
            Text("خذ زمام يومك")
                .font(ZimamType.hero)
                .lineSpacing(ZimamType.heroLineSpacing)
                .multilineTextAlignment(.center)
            Text("مهامك بالهجري والميلادي، ومرتبطة بأوقات الصلاة.")
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.inkMuted)
                .multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: ZimamSpacing.space3) {
                SignInWithAppleButton(.signIn) { request in
                    session.prepare(request)
                } onCompletion: { result in
                    Task { await session.complete(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(maxWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space11)
                if SessionStore.isGoogleConfigured {
                    GoogleButton(isBusy: session.isSigningInWithGoogle) {
                        Task { await session.signInWithGoogle() }
                    }
                    .frame(maxWidth: ZimamSpacing.space8 * 12)
                }
            }
            if let message = session.errorMessage {
                Text(message)
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.priorityHigh)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(ZimamSpacing.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZimamColor.surface)
    }
}

/// «المتابعة بحساب قوقل», drawn as Google's sign-in branding guidelines require: the colour
/// G logo (Assets: GoogleLogo, from the GoogleSignIn-iOS SDK), and Google's own fill, stroke
/// and text colours for the light and dark themes. This is the one allowed exception to the
/// design tokens (CLAUDE.md): these colours are Google's, not Zimam's, so they are written
/// here. Spacing, size and the Arabic font still come from the tokens (Google's Roboto has no
/// Arabic), and the button keeps the 44pt target and the Apple button's corner radius.
private struct GoogleButton: View {
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
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, ZimamSpacing.space3)
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
            .background(fill, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusSm))
            .overlay {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusSm)
                    .strokeBorder(stroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: ZimamRadius.radiusSm))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("المتابعة بحساب قوقل")
    }
}
