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
            SignInWithAppleButton(.signIn) { request in
                session.prepare(request)
            } onCompletion: { result in
                Task { await session.complete(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space11)
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
