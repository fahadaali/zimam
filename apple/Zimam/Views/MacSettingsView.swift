#if os(macOS)
import SwiftUI
import ZimamKit

/// The Mac's Settings window (⌘,): the same settings as the account menu. It is its own
/// scene, so it sets the direction, locale, font and calendar that RootView sets for the
/// main window.
struct MacSettingsView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            if session.isSignedIn {
                SettingsView()
            } else {
                Text("سجّل الدخول لتظهر الإعدادات.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: ZimamLayout.settingsWidth, minHeight: ZimamLayout.windowMinHeight)
        .background(ZimamColor.surface)
        .environment(\.dateFormatterZimam, DualDateFormatter(primary: session.user?.settings.calendar ?? .hijri, locale: ZimamLocale.current))
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, ZimamLocale.current)
        .font(ZimamType.body)
        .foregroundStyle(ZimamColor.ink)
        .tint(ZimamColor.brand)
        .formStyle(.grouped)
    }
}
#endif
