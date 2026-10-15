import SwiftUI
import ZimamKit

/// `zimam://import-callback?pending=<id>&source=<id>` (or `?error=<code>`), where the server's OAuth
/// callback for an import returns (api/DEVELOPMENT.md, «الاستيراد بإذن OAuth»). `ImportSourceView`
/// normally receives it from ASWebAuthenticationSession itself; this handles the link when the system
/// opens the app with it instead (the session was gone). Once someone is signed in, a sheet asks
/// whether to import into that account and only then starts it, or says why it did not start.
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
    /// Presents the import an opened callback link waits for, once the user is signed in.
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
                ImportCallbackView(callback: pending.callback, close: { links.pending = nil })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("إغلاق") { links.pending = nil }
                        }
                    }
            }
            // RootView sets this for the screens inside it; the sheet sits outside RootView.
            .environment(\.dateFormatterZimam, DualDateFormatter(primary: session.user?.settings.calendar ?? .hijri, locale: ZimamLocale.current))
        }
    }
}

/// The question before the import starts, then the job it started (followed); or the reason the
/// provider's page did not finish.
private struct ImportCallbackView: View {
    let callback: ImportCallback
    let close: () -> Void

    @Environment(SessionStore.self) private var session
    @State private var job: ImportJob?
    @State private var isConfirming = false
    @State private var errorMessage: String?

    var body: some View {
        switch callback {
        case .pending(let pending):
            if let job {
                ImportJobView(job: job)
            } else {
                confirmForm(pending)
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

    /// «استيراد بيانات Notion إلى حسابك فهد؟» with «استيراد» and «إلغاء». Someone else's flow
    /// (a provider link they sent) is refused by the server with 404, so nothing is imported.
    private func confirmForm(_ pending: ImportCallback.Pending) -> some View {
        Form {
            Section {
                Text(ImportText.confirmQuestion(source: pending.source,
                                                account: ImportText.accountLabel(name: session.user?.name, email: session.user?.email)))
                    .font(ZimamType.headline)
                Text(ImportText.confirmNote)
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }

            Section {
                Button {
                    Task { await confirm(pending) }
                } label: {
                    HStack(spacing: ZimamSpacing.space2) {
                        if isConfirming { ProgressView() }
                        Text(isConfirming ? "جارٍ البدء…" : "استيراد")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.zimamPrimary)
                .disabled(isConfirming)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Button("إلغاء", role: .cancel) { close() }
                    .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
                    .disabled(isConfirming)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.priorityHigh)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle("الاستيراد")
    }

    private func confirm(_ pending: ImportCallback.Pending) async {
        guard !isConfirming else { return }
        errorMessage = nil
        isConfirming = true
        defer { isConfirming = false }
        do {
            job = try await session.api.confirmOAuthImport(pending: pending.id, token: pending.token)
        } catch {
            errorMessage = ImportText.confirmMessage(for: error)
        }
    }
}
