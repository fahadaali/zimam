import EventKit
import SwiftData
import SwiftUI
import ZimamKit

// Apple Calendar events over Zimam's calendar and «اليوم», read only. An event is outlined, never
// filled, so it never reads as a task: its calendar's color is a small marker, its text is in
// Zimam's ink. All-day events and events that span days are bars; timed events show their time.
// The toolbar menu and the events' settings are in CalendarEventSettings.swift, an event's
// details in CalendarEventSheet.swift.

// MARK: Words

extension ArabicCount {
    /// «حدث واحد»، «حدثان»، «٣ أحداث»، «١١ حدثاً»، «١٠٠ حدث».
    static func events(_ count: Int, locale: Locale) -> String {
        let number = count.formatted(.number.locale(locale))
        switch count {
        case 1: return "حدث واحد"
        case 2: return "حدثان"
        default:
            switch count % 100 {
            case 3...10: return "\(number) أحداث"
            case 11...99: return "\(number) حدثاً"
            default: return "\(number) حدث"
            }
        }
    }
}

extension DualDateFormatter {
    /// The short line under an event in a list: «١٠:٠٠ ص – ١١:٠٠ ص», «طوال اليوم», or its days.
    func eventTime(_ item: ShownEvent) -> String {
        if item.span.isMultiDay { return spanText(item.span) }
        if item.event.isAllDay { return "طوال اليوم" }
        return "\(time(item.event.start)) – \(time(item.event.end))"
    }

    /// When the event is, in both calendars, for its details.
    func eventWhen(_ item: ShownEvent) -> [String] {
        let event = item.event
        if item.span.isMultiDay {
            if event.isAllDay { return [spanText(item.span)] }
            return ["يبدأ \(weekday(event.start))، \(dual(event.start, withYear: true))، \(time(event.start))",
                    "وينتهي \(weekday(event.end))، \(dual(event.end, withYear: true))، \(time(event.end))"]
        }
        let day = "\(weekday(event.start))، \(dual(event.start, withYear: true))"
        if event.isAllDay { return [day, "طوال اليوم"] }
        return [day, "\(time(event.start)) – \(time(event.end))"]
    }

    /// For VoiceOver: «اجتماع الفريق، ١٠:٠٠ ص – ١١:٠٠ ص، حدث في تقويم العمل».
    func eventAccessibility(_ item: ShownEvent) -> String {
        "\(item.title)، \(eventTime(item))، حدث في تقويم \(item.calendarTitle)"
    }
}

// MARK: Pieces

/// The calendar's color as a small dot: the only place its color is used.
struct EventMarker: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: ZimamSpacing.space2, height: ZimamSpacing.space2)
            .accessibilityHidden(true)
    }
}

/// An event in a day list: outlined, with its marker, title and time. Opens its details.
struct EventRow: View {
    let item: ShownEvent
    let onOpen: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: ZimamSpacing.space3) {
                EventMarker(color: item.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(formatter.eventTime(item))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: ZimamSpacing.space2)
                Image(systemName: "calendar")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ZimamSpacing.space3)
            .padding(.vertical, ZimamSpacing.space2)
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd).strokeBorder(ZimamColor.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(formatter.eventAccessibility(item))
        .accessibilityHint("يعرض تفاصيل الحدث")
    }
}

/// A day's events above its tasks: bars (all-day, spanning) first, then timed ones.
struct DayEventsList: View {
    let events: [ShownEvent]
    let onOpen: (ShownEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            ForEach(events) { item in
                EventRow(item: item) { onOpen(item) }
            }
        }
    }
}

/// Up to three outlined rings in a month cell (tasks are filled dots), or the count when more.
struct EventMarks: View {
    let count: Int

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        HStack(spacing: ZimamSpacing.space1 / 2) {
            if count > 3 {
                Text(formatter.number(count))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            } else {
                ForEach(0..<count, id: \.self) { _ in
                    Circle()
                        .strokeBorder(ZimamColor.inkMuted, lineWidth: ZimamSpacing.space1 / 4)
                        .frame(width: ZimamSpacing.space1 * 1.5, height: ZimamSpacing.space1 * 1.5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// All-day events and events that span days, as outlined bars across the week's columns (iPad, Mac).
struct EventLanes: View {
    let days: [String]
    let events: [ShownEvent]
    var maxLanes = 3
    let spacing: CGFloat
    let onOpen: (ShownEvent) -> Void

    var body: some View {
        let bars = events.filter(\.isWholeDay)
        let segments = SpanLayout.week(bars.map { (id: $0.id, span: $0.span) }, days: days, maxLanes: maxLanes).segments
        // Looked up per segment below; the first event with an id wins, as a search would.
        let barsById = Dictionary(bars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if !segments.isEmpty && !days.isEmpty {
            let laneHeight = ZimamSpacing.space11
            let lanes = (segments.map(\.lane).max() ?? 0) + 1
            let height = laneHeight * CGFloat(lanes) + spacing * CGFloat(lanes - 1)
            GeometryReader { geometry in
                let columnCount = days.count
                let column = (geometry.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
                ZStack(alignment: .topLeading) {
                    ForEach(segments, id: \.self) { segment in
                        if let item = barsById[segment.id] {
                            EventLaneBar(item: item) { onOpen(item) }
                                .frame(width: column * CGFloat(segment.columnCount) + spacing * CGFloat(segment.columnCount - 1),
                                       height: laneHeight)
                                .padding(.leading, (column + spacing) * CGFloat(segment.firstColumn))
                                .padding(.top, (laneHeight + spacing) * CGFloat(segment.lane))
                        }
                    }
                }
                .frame(width: geometry.size.width, height: height, alignment: .topLeading)
            }
            .frame(height: height)
        }
    }
}

/// One bar of `EventLanes`: its marker and title, opening its details.
struct EventLaneBar: View {
    let item: ShownEvent
    let onOpen: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: ZimamSpacing.space2) {
                EventMarker(color: item.color)
                Text(item.title)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, ZimamSpacing.space2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusSm))
            .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusSm).strokeBorder(ZimamColor.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(formatter.eventAccessibility(item))
    }
}

/// A timed event in a week column (iPad, Mac): outlined, its title and start time.
struct WeekEventCard: View {
    let item: ShownEvent
    let onOpen: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                HStack(spacing: ZimamSpacing.space1) {
                    EventMarker(color: item.color)
                    Text(formatter.time(item.event.start))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                Text(item.title)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(ZimamSpacing.space2)
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd).strokeBorder(ZimamColor.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(formatter.eventAccessibility(item))
    }
}
