#if DEBUG
import SwiftData
import SwiftUI
import ZimamKit

/// What every preview in this folder runs on: an in-memory store seeded with a sample day
/// (`PreviewData`), and the environment `ZimamApp` and `RootView` give the signed-in app.
/// The store is not the App Group's, and the sync engine talks to an address that never resolves,
/// so an edit made in the canvas stays in the canvas. `SessionStore` is the app's own, though: its
/// `api` is the real server with whatever token this device's Keychain holds (none in a fresh
/// simulator). The comments and attachments in a task's details, and «تسجيل الخروج» and «حذف الحساب»
/// in the settings, go through it, so those are not to be used in a live preview.
@MainActor
final class PreviewEnvironment {
    static let shared = PreviewEnvironment()

    let container: ModelContainer
    let session: SessionStore
    let sync: SyncEngine
    let location: LocationProvider
    let notifications: NotificationScheduler
    let subscriptions: SubscriptionStore
    /// Hijri first, as for a new account.
    let formatter = DualDateFormatter(primary: .hijri, locale: ZimamLocale.current)
    /// Riyadh, so a prayer-anchored task shows its time as it does once the location is known.
    let schedule = PrayerSchedule(latitude: 24.7136, longitude: 46.6753)

    private init() {
        let schema = Schema(zimamModelTypes)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        } catch {
            fatalError("Cannot open the in-memory store for the previews: \(error)")
        }
        // `.invalid` never resolves (RFC 2606): a sync started by an edit fails quietly.
        let api = APIClient(baseURL: URL(string: "https://preview.invalid")!, token: { nil })
        let session = SessionStore()
        let sync = SyncEngine(api: api, context: container.mainContext)
        let location = LocationProvider()
        // Never started: the previews watch no places.
        let places = PlaceMonitor(context: container.mainContext, sync: sync)
        let notifications = NotificationScheduler(context: container.mainContext, sync: sync, session: session,
                                                  location: location, places: places)
        self.container = container
        self.session = session
        self.sync = sync
        self.location = location
        self.notifications = notifications
        subscriptions = SubscriptionStore(api: api)
        PreviewData.seed(container.mainContext, formatter: formatter)
    }

    /// A task of the sample day, for the component previews.
    func task(_ id: UUID) -> TaskItem? {
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        return try? container.mainContext.fetch(descriptor).first
    }
}

extension View {
    /// The signed-in app's environment for a preview, as `ZimamApp` and `RootView` set it: the
    /// store, the five observable objects, Arabic from right to left, the date formatter and the
    /// prayer times, and Zimam's font, ink and tint.
    func zimamPreview(_ scheme: ColorScheme = .light) -> some View {
        let env = PreviewEnvironment.shared
        return self
            .environment(env.session)
            .environment(env.sync)
            .environment(env.location)
            .environment(env.notifications)
            .environment(env.subscriptions)
            .environment(\.dateFormatterZimam, env.formatter)
            .environment(\.prayerScheduleZimam, env.schedule)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, ZimamLocale.current)
            .font(ZimamType.body)
            .foregroundStyle(ZimamColor.ink)
            .tint(ZimamColor.brand)
            .modelContainer(env.container)
            .preferredColorScheme(scheme)
    }
}
#endif
