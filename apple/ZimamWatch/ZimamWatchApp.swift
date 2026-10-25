import SwiftUI
import ZimamKit

@main
struct ZimamWatchApp: App {
    @State private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchTodayView()
                .environment(model)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, ZimamLocale.current)
                .font(ZimamType.body)
                .foregroundStyle(ZimamColor.ink)
                .tint(ZimamColor.brand)
        }
        // Wakes in the background to keep the complications current (WatchRefresh.swift).
        .backgroundTask(.appRefresh(WatchRefresh.identifier)) {
            await WatchRefresh.run()
        }
    }
}
