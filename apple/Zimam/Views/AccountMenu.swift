import SwiftUI

/// The account and sync menu in the toolbar, under the account's photo (or a sync warning).
struct AccountMenu: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @State private var showingSettings = false
    @State private var signingOut = false

    init() {}

    var body: some View {
        Menu {
            if let name = session.user?.name { Text(name) }
            if let error = sync.lastError { Text(error) }
            if let notice = sync.refusedNotice { Text(notice) }
            Button("الإعدادات", systemImage: "gear") { showingSettings = true }
            Button("مزامنة الآن", systemImage: "arrow.triangle.2.circlepath") {
                Task { await sync.sync() }
            }
            Button("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                signingOut = true
            }
        } label: {
            if sync.lastError == nil {
                AvatarView(name: session.user?.name, size: ZimamSpacing.space8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("الحساب والمزامنة")
            } else {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .accessibilityLabel("الحساب والمزامنة")
            }
        }
        // On the menu itself: a dialog on one of its buttons would go with the closed menu.
        .signOutConfirmation($signingOut)
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}

extension View {
    /// «تسجيل الخروج» from the menu or the settings, the same way: once `requested` turns true it
    /// tries to send what is not in the account yet, then asks, and says so when some edits could not
    /// be sent (signing out wipes this device). `willSignOut` runs first (the settings sheet closes).
    func signOutConfirmation(_ requested: Binding<Bool>, willSignOut: @escaping () -> Void = {}) -> some View {
        modifier(SignOutConfirmation(requested: requested, willSignOut: willSignOut))
    }
}

private struct SignOutConfirmation: ViewModifier {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(SubscriptionStore.self) private var subscriptions
    @Binding var requested: Bool
    let willSignOut: () -> Void
    @State private var confirming = false
    @State private var unsent = false

    func body(content: Content) -> some View {
        content
            .task(id: requested) {
                guard requested else { return }
                // Offline this ends at once; on a slow network it waits a little, not for the request timeout.
                if NetworkMonitor.shared.isOnline, sync.hasUnsentChanges {
                    _ = await sync.sync(waitingAtMost: .seconds(5))
                }
                unsent = sync.hasUnsentChanges
                requested = false
                confirming = true
            }
            .confirmationDialog("تسجيل الخروج؟", isPresented: $confirming, titleVisibility: .visible) {
                Button("تسجيل الخروج", role: .destructive) { signOut() }
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text(unsent
                     ? "لم تُرسل بعض تعديلاتك إلى حسابك بعد، وتُفقد من هذا الجهاز إن سجّلت الخروج الآن."
                     : "تُمسح بيانات زمام من هذا الجهاز، وتبقى محفوظة في حسابك.")
            }
    }

    private func signOut() {
        willSignOut()
        subscriptions.signedOut()
        Task {
            await session.signOut()
            sync.reset()
        }
    }
}
