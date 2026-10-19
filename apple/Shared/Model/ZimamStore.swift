import Foundation
import SwiftData
import WidgetKit

/// What the app, its widgets and its intents share on this device.
nonisolated enum ZimamShared {
    /// The App Group that holds the local store and the few settings the widgets read.
    /// Register it in the developer account (see docs/setup.md).
    static let appGroup = "group.app.zimam.ios"

    /// Settings shared with the widgets. Falls back to the process's own defaults if the
    /// App Group is missing from the build's entitlements. UserDefaults locks internally and
    /// Apple documents it as safe to use from any thread; the SDK just does not mark it Sendable.
    nonisolated(unsafe) static let defaults: UserDefaults = UserDefaults(suiteName: appGroup) ?? .standard

    /// Asks WidgetKit to redraw the widgets after the data or the settings changed.
    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// The one place that opens the local store. It lives in the App Group container so the
/// app, the widget extension and the intents read and write the same data. Each process
/// opens it once; the app and its intents share `shared`.
enum ZimamStore {
    static let shared: ModelContainer = makeContainer()

    /// True when the app is only the host of its unit tests (ZimamTests). The store is then kept
    /// in memory, so the tests never read or write the person's data, and a test build that is
    /// not signed (and so cannot reach the App Group) still launches.
    nonisolated static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    static func makeContainer() -> ModelContainer {
        let schema = Schema(zimamModelTypes)
        if isTestHost {
            do {
                return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            } catch {
                fatalError("Cannot open the in-memory store for the tests: \(error)")
            }
        }
        // Without the App Group in the signed build (a signing mistake), keep the store in the
        // app's own container rather than failing to launch; the widgets then show nothing.
        let hasGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZimamShared.appGroup) != nil
        let configuration = hasGroup
            ? ModelConfiguration(schema: schema, groupContainer: .identifier(ZimamShared.appGroup))
            : ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Cannot open the local store: \(error)")
        }
    }
}

/// The app's sync engine, when this process has one: the app sets it at launch, the widget
/// extension never does. Intents pass it to `Store` so their edits sync right away.
@MainActor
enum LiveSync {
    static var engine: (any SyncScheduling)?
}
