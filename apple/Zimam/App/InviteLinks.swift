import SwiftUI
import ZimamKit

/// Invite links that open the app: the universal link `https://<site>/join/#<code>`
/// (Associated Domains in apple/project.yml, served by web/public/.well-known/apple-app-site-association)
/// and `zimam://join/<code>` from «فتح في التطبيق» on the web join page. The code waits here
/// until someone is signed in, then the «الانضمام بدعوة» sheet opens with it filled in.
@MainActor
@Observable
final class InviteLinks {
    static let shared = InviteLinks()

    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let code: String
    }

    var pending: Pending?

    /// Takes the URL if it is an invite link with a code; false leaves it to other handlers.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard InviteCode.isInviteLink(url), let code = InviteCode.extract(from: url.absoluteString) else { return false }
        pending = Pending(code: code)
        return true
    }
}

extension View {
    /// Presents the join sheet for an opened invite link once the user is signed in.
    func inviteLinkSheet() -> some View {
        modifier(InviteLinkSheet())
    }
}

private struct InviteLinkSheet: ViewModifier {
    @Environment(SessionStore.self) private var session

    func body(content: Content) -> some View {
        let links = InviteLinks.shared
        // Read here so the sheet appears as soon as a link arrives or sign-in finishes.
        let current = session.isSignedIn ? links.pending : nil
        content.sheet(item: Binding(get: { current }, set: { links.pending = $0 })) { pending in
            JoinProjectView(code: pending.code)
                // RootView sets this for the screens inside it; the sheet sits outside RootView.
                .environment(\.dateFormatterZimam, DualDateFormatter(primary: session.user?.settings.calendar ?? .hijri, locale: ZimamLocale.current))
        }
    }
}
