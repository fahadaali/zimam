import SwiftUI
import WidgetKit

@main
struct ZimamWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}

/// Today's tasks: small (the count and the next task), medium (four tasks),
/// large (today with the next prayer-anchored task and the dual date).
struct TodayWidget: Widget {
    static let kind = "app.zimam.today"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("اليوم")
        .description("مهام اليوم مع التاريخين، وإنجازها بلمسة.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
