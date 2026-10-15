import SwiftUI
import ZimamKit

/// `zimam://import-callback?job=<id>` (or `?error=<code>`), where the server's OAuth callback for an
/// import returns (api/DEVELOPMENT.md, «الاستيراد بإذن OAuth»). `ImportSourceView` normally
/// receives it from ASWebAuthenticationSession itself; this handles the link when the system
/// opens the app with it instead (the session was gone), and shows the job, or why it did not start,
/// in a sheet once someone is signed in.
@MainActor
@Observable
final class ImportLinks {
    static let shared = ImportLinks()

    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let callback: ImportCallback
    }

    var pending: Pending?

    private init() {}

    /// Takes the URL if it is an import callback; false leaves it to other handlers.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let callback = ImportCallback(url: url) else { return false }
        pending = Pending(callback: callback)
        return true
    }
}

extension View {
    /// Presents the import an opened callback link names, once the user is signed in.
    func importLinkSheet() -> some View {
        modifier(ImportLinkSheet())
    }
}

private struct ImportLinkSheet: ViewModifier {
    @Environment(SessionStore.self) private var session

    func body(content: Content) -> some View {
        let links = ImportLinks.shared
        let current = session.isSignedIn ? links.pending : nil
        content.sheet(item: Binding(get: { current }, set: { links.pending = $0 })) { pending in
            NavigationStack {
                ImportCallbackView(callback: pending.callback)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("تم") { links.pending = nil }
                        }
                    }
            }
            // RootView sets this for the screens inside it; the sheet sits outside RootView.
            .environment(\.dateFormatterZimam, DualDateFormatter(primary: session.user?.settings.calendar ?? .hijri, locale: ZimamLocale.current))
        }
    }
}

/// The job the callback named (loaded, then followed), or the reason it did not start.
private struct ImportCallbackView: View {
    let callback: ImportCallback

    @Environment(SessionStore.self) private var session
    @State private var job: ImportJob?
    @State private var loadFailed = false

    var body: some View {
        switch callback {
        case .job(let id):
            if let job {
                ImportJobView(job: job)
            } else {
                Form {
                    if loadFailed {
                        Text("بدأ الاستيراد، وتعذّر عرض حالته الآن. تجده في «الإعدادات» ثم «استيراد المهام».")
                            .font(ZimamType.callout)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(ZimamColor.surface)
                .navigationTitle("الاستيراد")
                .task(id: id) {
                    do {
                        job = try await session.api.importJob(id: id)
                    } catch {
                        loadFailed = true
                    }
                }
            }
        case .failure(let code):
            Form {
                Label(ImportText.oauthMessage(code), systemImage: "exclamationmark.triangle")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.priorityHigh)
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("الاستيراد")
        }
    }
}
