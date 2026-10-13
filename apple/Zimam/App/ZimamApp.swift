import SwiftData
import SwiftUI
import ZimamKit

@main
struct ZimamApp: App {
    private let container: ModelContainer
    @State private var session: SessionStore
    @State private var sync: SyncEngine

    init() {
        do {
            container = try ModelContainer(for: Schema(zimamModelTypes))
        } catch {
            fatalError("Cannot open the local store: \(error)")
        }
        let session = SessionStore()
        _session = State(initialValue: session)
        _sync = State(initialValue: SyncEngine(api: session.api, context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(sync)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, ZimamLocale.current)
                .font(ZimamType.body)
                .foregroundStyle(ZimamColor.ink)
                .tint(ZimamColor.brand)
        }
        .modelContainer(container)
    }
}
