import SwiftUI
import WidgetKit

@main
struct ZimamWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        // The home-screen family: the year, the month, the week, what is next, and the matrix.
        YearProgressWidget()
        MonthWidget()
        WeekWidget()
        UpcomingWidget()
        MatrixWidget()
        // The next prayer's countdown, on the home screen and the Lock Screen (PrayerWidget.swift).
        PrayerWidget()
        #if os(iOS)
        // The Lock Screen (LockScreenWidget.swift) and «المهمة الجارية» (FocusLiveActivity.swift).
        LockScreenWidget()
        FocusLiveActivity()
        #endif
    }
}

/// Today's tasks: small (the count and the next task), medium (four tasks),
/// large (today with the next prayer-anchored task and the dual date).
struct TodayWidget: Widget {
    static let kind = ZimamShared.WidgetKind.today

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("اليوم")
        .description("مهام اليوم مع التاريخين، وإنجازها بلمسة.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
