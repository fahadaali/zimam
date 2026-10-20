import SwiftData
import SwiftUI
import ZimamKit

@main
struct ZimamApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    private let container: ModelContainer
    @State private var session: SessionStore
    @State private var sync: SyncEngine
    @State private var location: LocationProvider
    @State private var notifications: NotificationScheduler
    @State private var subscriptions: SubscriptionStore

    init() {
        // Settings the widgets read moved to the App Group; copy them over before anything reads them.
        SharedSettings.migrateFromStandardDefaults()
        // The store lives in the App Group, shared with the widgets and with the intents in this process.
        container = ZimamStore.shared
        let session = SessionStore()
        let sync = SyncEngine(api: session.api, context: container.mainContext)
        let location = LocationProvider()
        // Listens at launch, so a place crossing that woke the app in the background is delivered.
        let places = PlaceMonitor(context: container.mainContext, sync: sync)
        // Not while hosting the unit tests: they must not watch the device's places.
        if !ZimamStore.isTestHost { places.start() }
        // Created at launch so the notification delegate is set before any action arrives.
        let notifications = NotificationScheduler(context: container.mainContext, sync: sync, session: session,
                                                  location: location, places: places)
        // Weak where the closure's owner is reachable from what it captures (the scheduler holds
        // the engine, the provider is its own owner): those would be reference cycles.
        sync.onDataChanged = { [weak notifications] in
            notifications?.reschedule()
            ZimamShared.reloadWidgets()
            #if os(iOS)
            // «المهمة الجارية» ends once its task is done or deleted, wherever that happened.
            FocusActivity.endFinished(in: ZimamStore.shared.mainContext)
            #endif
            // Open tasks in Spotlight, for system search, Siri and Apple Intelligence.
            TaskSpotlight.shared.scheduleUpdate()
            // Saved places in Siri's phrases («ذكرني في زمام إذا وصلت البيت»).
            ZimamShortcuts.updateAppShortcutParameters()
        }
        location.onChange = { [weak notifications, session, weak location] in
            notifications?.reschedule()
            #if os(iOS)
            // The watch's prayer complications follow the place.
            WatchLink.shared.sendSession()
            #endif
            let coordinate = location?.coordinate
            Task { await session.sharePlace(latitude: coordinate?.latitude, longitude: coordinate?.longitude) }
        }
        // Reminders beyond the local window come as pushes; the token is sent with this session.
        PushRegistration.shared.api = session.api
        // Siri and Shortcuts run their intents in this process; their edits sync through the same engine.
        LiveSync.engine = sync
        // The system's background wakes renew the notification window (adhan and iqama alerts).
        BackgroundRefresh.scheduler = notifications
        #if os(iOS)
        // Hands the session to the Apple Watch app.
        WatchLink.shared.start()
        #endif
        _session = State(initialValue: session)
        _sync = State(initialValue: sync)
        _location = State(initialValue: location)
        _notifications = State(initialValue: notifications)
        // «زمام الاحترافية»: renewals and purchases made elsewhere arrive while the app runs.
        let subscriptions = SubscriptionStore(api: session.api)
        subscriptions.start()
        _subscriptions = State(initialValue: subscriptions)
    }

    var body: some Scene {
        WindowGroup {
            if ZimamStore.isTestHost {
                // The unit tests run inside the app: nothing of the app starts, no sync, no
                // notifications, no window content.
                Color.clear
            } else {
                RootView()
                    // The join sheet for an invite link (App/InviteLinks.swift); inside the environment below.
                    .inviteLinkSheet()
                    // An import's OAuth callback opened outside its web session (Import/ImportLinks.swift).
                    .importLinkSheet()
                    .environment(session)
                    .environment(sync)
                    .environment(location)
                    .environment(notifications)
                    .environment(subscriptions)
                    .environment(\.layoutDirection, .rightToLeft)
                    .environment(\.locale, ZimamLocale.current)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
                    .tint(ZimamColor.brand)
                    // Google's sign-in page returns here through the reversed client ID scheme, the
                    // widgets through zimam://task/<id>, zimam://day/<day>, zimam://today and
                    // zimam://calendar (App/AppLinks.swift), and «فتح في التطبيق» on the web join page
                    // through zimam://join/<code>. An import's OAuth flow returns through
                    // zimam://import-callback?pending=<id> (Import/ImportLinks.swift).
                    .onOpenURL { url in
                        if SessionStore.handleOpenURL(url) { return }
                        if AppLinks.open(url) { return }
                        if ImportLinks.shared.open(url) { return }
                        InviteLinks.shared.open(url)
                    }
                    // Universal links: https://<site>/join/#<code> (Associated Domains in project.yml).
                    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                        if let url = activity.webpageURL { InviteLinks.shared.open(url) }
                    }
            }
        }
        .modelContainer(container)
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
        #endif
        #if os(macOS)
        // «مهمة جديدة» (⌘N) and the «المهام» menu (AppNavigation.swift).
        .commands { ZimamCommands() }
        #endif

        #if os(macOS)
        // ⌘, opens the settings in their own window.
        Settings {
            MacSettingsView()
                .environment(session)
                .environment(sync)
                .environment(location)
                .environment(notifications)
        }
        .modelContainer(container)
        #endif
    }
}
