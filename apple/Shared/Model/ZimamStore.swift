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

    /// Asks WidgetKit to redraw the widgets after the settings, the place or the account changed.
    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Each widget's `kind`. The widgets (ZimamWidgets/) take theirs from here, so the ones that
    /// show tasks cannot be left out of `tasks`.
    nonisolated enum WidgetKind {
        static let today = "app.zimam.today"
        static let next = "app.zimam.next"
        static let upcoming = "app.zimam.upcoming"
        static let week = "app.zimam.week"
        static let month = "app.zimam.month"
        static let matrix = "app.zimam.matrix"
        static let prayer = "app.zimam.prayer"
        static let year = "app.zimam.year"

        /// The widgets that show tasks. The prayer and year widgets read none, so a task edit or
        /// a sync leaves them alone.
        static let tasks = [today, next, upcoming, week, month, matrix]
    }

    /// Asks WidgetKit to redraw the widgets that show tasks, after a task edit or a sync.
    static func reloadTaskWidgets() {
        for kind in WidgetKind.tasks {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
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
        let hasGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZimamShared.appGroup)
            .map(isUsableGroupContainer) ?? false
        let configuration = hasGroup
            ? ModelConfiguration(schema: schema, groupContainer: .identifier(ZimamShared.appGroup))
            : ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Cannot open the local store: \(error)")
        }
    }

    /// iOS has no container URL for a group the build is not entitled to. macOS returns one all
    /// the same, so the Mac checks that the folder SwiftData keeps the store in can be made there.
    nonisolated private static func isUsableGroupContainer(_ url: URL) -> Bool {
        #if os(macOS)
        let support = url.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            return FileManager.default.isWritableFile(atPath: support.path(percentEncoded: false))
        } catch {
            return false
        }
        #else
        return true
        #endif
    }
}

/// The app's sync engine, when this process has one: the app sets it at launch, the widget
/// extension never does. Intents pass it to `Store` so their edits sync right away.
@MainActor
enum LiveSync {
    static var engine: (any SyncScheduling)?
    /// Replans the notifications now, from what is saved here, then sends what is waiting and
    /// pulls, waiting at most `limit`: for an intent or a background wake, after which the system
    /// may suspend the app at once, maybe before the network answers. A sync that ends in time
    /// replans again with what it brought; one that does not goes on while the app still runs.
    /// The app sets it at launch; nil in the widget extension.
    static var flush: (@MainActor (_ limit: Duration) async -> Void)?
    /// How long an intent waits for its edit to go out: Siri and a widget's button answer only
    /// once it returns, and the system ends an intent that takes too long.
    static let intentWait: Duration = .seconds(5)
}
