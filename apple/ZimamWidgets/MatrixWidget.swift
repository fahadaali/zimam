import AppIntents
import SwiftUI
import WidgetKit
import ZimamKit

/// «المصفوفة»: one quadrant of the priority matrix per widget («مهم وعاجل»، «مهم»، «عاجل»،
/// «يوماً ما»), chosen when editing it. Its icon, title and count, then its tasks with their due
/// time or day and a completion circle, and «+n أخرى» for the rest. Four of them side by side make
/// the whole matrix.
struct MatrixWidget: Widget {
    static let kind = "app.zimam.matrix"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: MatrixWidgetConfiguration.self, provider: MatrixProvider()) { entry in
            MatrixWidgetView(entry: entry)
        }
        .configurationDisplayName("المصفوفة")
        .description("ربع من مصفوفة الأولويات: مهم وعاجل، مهم، عاجل، يوماً ما.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

/// The quadrant a matrix widget shows, as the widget's setting.
enum MatrixQuadrantOption: String, AppEnum {
    case importantUrgent, important, urgent, someday

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "الربع"
    static let caseDisplayRepresentations: [MatrixQuadrantOption: DisplayRepresentation] = [
        .importantUrgent: "مهم وعاجل",
        .important: "مهم",
        .urgent: "عاجل",
        .someday: "يوماً ما",
    ]

    var quadrant: WidgetQuadrant {
        switch self {
        case .importantUrgent: .importantUrgent
        case .important: .important
        case .urgent: .urgent
        case .someday: .someday
        }
    }
}

struct MatrixWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "المصفوفة"
    static let description = IntentDescription("اختر الربع الذي يعرضه الويدجت.")

    @Parameter(title: "الربع", default: .importantUrgent)
    var quadrant: MatrixQuadrantOption

    init() {}
}

struct MatrixEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let quadrant: WidgetQuadrant
}

/// An entry now and at each of today's task times (a time gone turns late), and a new timeline at
/// midnight, when «عاجل» moves on by a day.
struct MatrixProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MatrixEntry {
        let now = Date()
        return MatrixEntry(date: now, snapshot: .placeholder(now: now), quadrant: .importantUrgent)
    }

    func snapshot(for configuration: MatrixWidgetConfiguration, in context: Context) async -> MatrixEntry {
        let now = Date()
        let snapshot = context.isPreview ? WidgetSnapshot.placeholder(now: now) : WidgetSnapshot.load(now: now)
        return MatrixEntry(date: now, snapshot: snapshot, quadrant: configuration.quadrant.quadrant)
    }

    func timeline(for configuration: MatrixWidgetConfiguration, in context: Context) async -> Timeline<MatrixEntry> {
        let now = Date()
        let snapshot = WidgetSnapshot.load(now: now)
        let entries = snapshot.entryDates(now: now, atTaskTimes: true).map {
            MatrixEntry(date: $0, snapshot: snapshot, quadrant: configuration.quadrant.quadrant)
        }
        return Timeline(entries: entries, policy: .after(snapshot.nextMidnight))
    }
}

struct MatrixWidgetView: View {
    let entry: MatrixEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @ScaledMetric(relativeTo: .headline) private var header = ZimamSpacing.space8
    @ScaledMetric(relativeTo: .caption) private var moreLine = ZimamSpacing.space4 + ZimamSpacing.space1

    var body: some View {
        let tone = WidgetTone(mode: mode)
        let snapshot = entry.snapshot
        let quadrant = entry.quadrant
        let tasks = quadrantTasks(quadrant, snapshot: snapshot)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ZimamSpacing.space1) {
                Image(systemName: quadrant.symbol)
                    .accessibilityHidden(true)
                Text(quadrant.title)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if snapshot.isSignedIn {
                    WidgetCountBadge(count: tasks.count, color: quadrant.color, tone: tone, locale: snapshot.formatter.locale)
                }
            }
            .font(ZimamType.headline)
            .foregroundStyle(tone.tinted(quadrant.color))
            .widgetAccentable()
            .padding(.horizontal, ZimamSpacing.space1)
            .frame(height: header)

            if !snapshot.isSignedIn {
                WidgetNote(text: "سجّل الدخول في زمام لتظهر مهامك هنا.", tone: tone)
            } else if tasks.isEmpty {
                WidgetNote(text: "لا مهام هنا.", tone: tone)
                    .padding(.horizontal, ZimamSpacing.space1)
            } else {
                GeometryReader { geometry in
                    rows(tasks, snapshot: snapshot, tone: tone, size: geometry.size)
                }
            }
        }
        .zimamWidget(padding: ZimamSpacing.space2)
    }

    /// The quadrant's open tasks: dated ones first by day and time, then by priority and the
    /// user's order. By the matrix contract every open task counts, subtasks included.
    private func quadrantTasks(_ quadrant: WidgetQuadrant, snapshot: WidgetSnapshot) -> [WidgetItem] {
        snapshot.items
            .filter { WidgetQuadrant.classify(priority: $0.priority, dueDay: $0.dueDay, tomorrow: snapshot.tomorrow) == quadrant }
            .sorted { a, b in
                (a.dueDay == nil ? 1 : 0, a.dueDay ?? "", a.minuteOfDay ?? -1, -a.priority.rawValue, a.sortOrder)
                    < (b.dueDay == nil ? 1 : 0, b.dueDay ?? "", b.minuteOfDay ?? -1, -b.priority.rawValue, b.sortOrder)
            }
    }

    /// As many 44pt rows as fit: one column in the small widget, two in the medium one (read
    /// row by row, from the leading side), then «+n أخرى».
    @ViewBuilder
    private func rows(_ tasks: [WidgetItem], snapshot: WidgetSnapshot, tone: WidgetTone, size: CGSize) -> some View {
        let columns = family == .systemSmall ? 1 : 2
        let fittingRows = max(0, Int(size.height / WidgetMetrics.row))
        let rowsShown = tasks.count > fittingRows * columns
            ? max(0, Int((size.height - moreLine) / WidgetMetrics.row))
            : fittingRows
        let shown = Array(tasks.prefix(rowsShown * columns))
        let hidden = tasks.count - shown.count
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<Int((Double(shown.count) / Double(columns)).rounded(.up)), id: \.self) { row in
                HStack(spacing: ZimamSpacing.space1) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < shown.count {
                            MatrixRow(item: shown[index], snapshot: snapshot, now: entry.date, tone: tone,
                                      opensTask: family != .systemSmall)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: WidgetMetrics.row)
                        }
                    }
                }
            }
            if hidden > 0 {
                Text("+\(snapshot.formatter.number(hidden)) أخرى")
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.muted)
                    .frame(height: moreLine)
                    .padding(.leading, ZimamSpacing.space3)
                    .accessibilityLabel("\(ArabicCount.tasks(hidden, locale: snapshot.formatter.locale)) غيرها")
            }
        }
    }
}

/// A task in a quadrant: the completion circle in the task's priority color, the title, and when
/// it is due under it. Beyond the small widget the title opens the task.
private struct MatrixRow: View {
    let item: WidgetItem
    let snapshot: WidgetSnapshot
    let now: Date
    let tone: WidgetTone
    let opensTask: Bool

    var body: some View {
        HStack(spacing: 0) {
            WidgetCompleteButton(item: item, tone: tone)
            if opensTask {
                Link(destination: AppLink.task(item.id).url) { label }
            } else {
                label
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: WidgetMetrics.row)
    }

    private var label: some View {
        let when = widgetWhenText(item, snapshot: snapshot, now: now)
        let late = widgetIsLate(item, snapshot: snapshot, now: now)
        return VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .font(ZimamType.callout)
                .foregroundStyle(tone.ink)
                .lineLimit(1)
            if let when {
                Text(when)
                    .font(ZimamType.caption)
                    .foregroundStyle(late ? tone.late : item.prayer != nil ? tone.prayer : tone.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, when, priorityLabel(item.priority)].compactMap { $0 }.joined(separator: "، "))
    }
}
