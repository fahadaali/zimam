import SwiftUI

/// The account and sync menu in the toolbar, under the account's photo (or a sync warning).
struct AccountMenu: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @State private var showingSettings = false

    init() {}

    var body: some View {
        Menu {
            if let name = session.user?.name { Text(name) }
            if let error = sync.lastError { Text(error) }
            Button("الإعدادات", systemImage: "gear") { showingSettings = true }
            Button("مزامنة الآن", systemImage: "arrow.triangle.2.circlepath") {
                Task { await sync.sync() }
            }
            Button("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task {
                    await session.signOut()
                    sync.reset()
                }
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
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}
