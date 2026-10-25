import EventKit
import Foundation
import Observation
import SwiftUI
import ZimamKit

/// An Apple Calendar event occurrence ready to draw over Zimam's calendar.
struct ShownEvent: Identifiable {
    let event: AppleCalendarEvent
    /// The days it covers in the user's time zone.
    let span: DaySpan
    let calendarTitle: String
    /// The calendar's own color, for the small marker only; text stays in Zimam's tokens.
    let color: Color

    var id: String { event.id }

    /// Drawn as a bar: an all-day event, or one that spans days.
    var isWholeDay: Bool { event.isAllDay || span.isMultiDay }

    /// The title, or a word for an event without one.
    var title: String {
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "حدث بلا عنوان" : trimmed
    }
}

/// Apple Calendar on this device, read only: «إظهار أحداث التقويم» in the calendar and «اليوم»,
/// the calendars chosen for it, and the events of the days on screen. Nothing is read until the user
/// turns the events on or imports them, and nothing leaves the device unless the user turns an event
/// into a task. The import screen (`CalendarImporter`) shares the event store and the permission.
@MainActor
@Observable
final class CalendarEvents {
    static let shared = CalendarEvents()

    enum Access: Equatable {
        case notDetermined, granted, denied, writeOnly, restricted
    }

    private(set) var access: Access
    /// «إظهار أحداث التقويم», remembered on this device. Off until the user turns it on.
    private(set) var isShowing: Bool
    /// Calendars the user turned off for showing; a calendar added later shows by default.
    private(set) var hiddenCalendars: Set<String>
    /// The device's event calendars, by account and name.
    private(set) var calendars: [AppleCalendarImport.CalendarRef] = []
    /// Subscribed and birthday calendars, left unchosen by default when importing.
    private(set) var subscribedCalendars: Set<String> = []
    private(set) var errorMessage: String?
    /// Bumped when the events may have changed (an edit in Calendar, a setting here), so views read again.
    private(set) var revision = 0

    @ObservationIgnored private var cache: [String: [ShownEvent]] = [:]
    @ObservationIgnored private var colors: [String: Color] = [:]
    @ObservationIgnored private var storage: EKEventStore?
    @ObservationIgnored private var observer: NSObjectProtocol?
    private let defaults: UserDefaults

    private static let showKey = "calendarEvents.show"
    private static let hiddenKey = "calendarEvents.hiddenCalendars"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        access = Self.currentAccess()
        isShowing = defaults.bool(forKey: Self.showKey)
        hiddenCalendars = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    /// Made on first use; it watches Calendar for changes from then on.
    var store: EKEventStore {
        if let storage { return storage }
        let made = EKEventStore()
        storage = made
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: made, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
        return made
    }

    static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .writeOnly: return .writeOnly
        case .restricted: return .restricted
        default: return .denied
        }
    }

    // MARK: Permission and settings

    /// Reads the permission again (it may have changed in Settings) and the calendars when allowed.
    func refresh() {
        let now = Self.currentAccess()
        if now != access {
            access = now
            bump()
        }
        if access == .granted { loadCalendars() }
    }

    /// Shows the system prompt the first time; afterwards the answer comes from Settings.
    func requestAccess() async {
        errorMessage = nil
        do {
            let granted = try await store.requestFullAccessToEvents()
            access = granted ? .granted : Self.currentAccess()
        } catch {
            access = Self.currentAccess()
            if access != .granted { errorMessage = "تعذّر طلب الإذن. حاول مرة أخرى." }
        }
        if access == .granted { loadCalendars() }
        bump()
    }

    /// Turns the events on or off. Turning them on asks for access the first time.
    func setShowing(_ on: Bool) async {
        isShowing = on
        defaults.set(on, forKey: Self.showKey)
        if on && access == .notDetermined { await requestAccess() }
        if on && access == .granted && calendars.isEmpty { loadCalendars() }
        bump()
    }

    func isShown(_ calendarId: String) -> Bool { !hiddenCalendars.contains(calendarId) }

    func setCalendar(_ calendarId: String, shown: Bool) {
        if shown { hiddenCalendars.remove(calendarId) } else { hiddenCalendars.insert(calendarId) }
        defaults.set(Array(hiddenCalendars).sorted(), forKey: Self.hiddenKey)
        bump()
    }

    /// The calendar's color, for its marker.
    func color(for calendarId: String) -> Color {
        colors[calendarId] ?? ZimamColor.inkMuted
    }

    func loadCalendars() {
        let found = store.calendars(for: .event)
        var newColors: [String: Color] = [:]
        for calendar in found {
            let cgColor: CGColor? = calendar.cgColor
            if let cgColor { newColors[calendar.calendarIdentifier] = Color(cgColor: cgColor) }
        }
        colors = newColors
        subscribedCalendars = Set(found.filter { $0.type == .subscription || $0.type == .birthday }.map(\.calendarIdentifier))
        calendars = found
            .map { calendar in
                let source: EKSource? = calendar.source
                return AppleCalendarImport.CalendarRef(id: calendar.calendarIdentifier, title: calendar.title,
                                                       sourceTitle: source?.title ?? "")
            }
            .sorted { a, b in
                if a.sourceTitle != b.sourceTitle { return a.sourceTitle.localizedStandardCompare(b.sourceTitle) == .orderedAscending }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }

    // MARK: Events on screen

    /// The shown calendars' event occurrences that touch `first…last` (API days), sorted for a day
    /// list. Empty while the events are off or not allowed. Read in `body`: it follows `revision`.
    func events(from first: String, to last: String, timeZone: TimeZone) -> [ShownEvent] {
        guard isShowing, access == .granted else { return [] }
        let key = "\(revision)|\(first)|\(last)|\(timeZone.identifier)"
        if let cached = cache[key] { return cached }

        let days = DualDateFormatter(timeZone: timeZone)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        guard let start = days.date(fromDay: first), let lastStart = days.date(fromDay: last),
              let end = gregorian.date(byAdding: .day, value: 1, to: lastStart) else { return [] }
        let chosen = store.calendars(for: .event).filter { isShown($0.calendarIdentifier) }
        var result: [ShownEvent] = []
        if !chosen.isEmpty {
            let titles = Dictionary(chosen.map { ($0.calendarIdentifier, $0.title) }, uniquingKeysWith: { a, _ in a })
            var markers: [String: Color] = [:]
            for calendar in chosen {
                let cgColor: CGColor? = calendar.cgColor
                if let cgColor { markers[calendar.calendarIdentifier] = Color(cgColor: cgColor) }
            }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
            result = store.events(matching: predicate)
                .compactMap { EventKitEvents.event(from: $0) }
                .map { event in
                    ShownEvent(event: event, span: event.span(timeZone: timeZone),
                               calendarTitle: titles[event.calendarId] ?? "",
                               color: markers[event.calendarId] ?? ZimamColor.inkMuted)
                }
                .sorted { AppleCalendarEvent.dayOrder($0.event, $1.event, timeZone: timeZone) }
        }
        // A few ranges at once: the calendar and «اليوم» may both be on screen.
        if cache.count > 6 { cache.removeAll() }
        cache[key] = result
        return result
    }

    /// The occurrence in EventKit, to show it in Calendar's own view.
    func ekEvent(for event: AppleCalendarEvent) -> EKEvent? {
        guard access == .granted else { return nil }
        let predicate = store.predicateForEvents(withStart: event.start.addingTimeInterval(-1),
                                                 end: event.end.addingTimeInterval(1), calendars: nil)
        let match = store.events(matching: predicate).first { candidate in
            let identifier: String? = candidate.eventIdentifier
            let occurrence: Date? = candidate.occurrenceDate
            return identifier == event.eventId && occurrence == event.occurrenceDate
        }
        if let match { return match }
        return event.eventId.flatMap { store.event(withIdentifier: $0) }
    }

    // MARK: Import

    /// Every occurrence in the chosen calendars from `start` to `end`, and for each counted series
    /// (a rule with a number of times) the start of its first occurrence, for `AppleCalendarImport.plan`.
    /// Read off the main actor, up to a year of events, with a store of its own: the permission is
    /// the app's, and no `EKEventStore` crosses between actors.
    @concurrent nonisolated static func occurrences(in calendarIds: Set<String>, from start: Date, to end: Date) async
        -> (events: [AppleCalendarEvent], seriesStarts: [String: Date]) {
        let store = EKEventStore()
        let chosen = store.calendars(for: .event).filter { calendarIds.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return ([], [:]) }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
        var events: [AppleCalendarEvent] = []
        var seriesStarts: [String: Date] = [:]
        for item in store.events(matching: predicate) {
            guard let event = EventKitEvents.event(from: item) else { continue }
            events.append(event)
            if event.repeatRule?.count != nil, seriesStarts[event.externalId] == nil,
               let identifier = event.eventId, let first = store.event(withIdentifier: identifier) {
                let firstStart: Date? = first.startDate
                if let firstStart { seriesStarts[event.externalId] = firstStart }
            }
        }
        return (events, seriesStarts)
    }

    // MARK: Changes

    private func storeChanged() {
        if access == .granted { loadCalendars() }
        bump()
    }

    private func bump() {
        cache.removeAll()
        revision += 1
    }
}

/// EventKit's events as `AppleCalendarEvent` values. Not tied to the main actor: the import reads
/// them off it (`CalendarEvents.occurrences`).
nonisolated enum EventKitEvents {
    static func event(from item: EKEvent) -> AppleCalendarEvent? {
        let startDate: Date? = item.startDate
        guard let start = startDate else { return nil }
        let endDate: Date? = item.endDate
        let external: String? = item.calendarItemExternalIdentifier
        let id: String
        if let external, !external.isEmpty {
            id = external
        } else {
            id = item.calendarItemIdentifier
        }
        let title: String? = item.title
        let eventId: String? = item.eventIdentifier
        let occurrence: Date? = item.occurrenceDate
        let calendar: EKCalendar? = item.calendar
        let rule = item.hasRecurrenceRules ? item.recurrenceRules?.first.flatMap(EventKitReminders.rule(from:)) : nil
        return AppleCalendarEvent(
            externalId: id,
            eventId: eventId,
            calendarId: calendar?.calendarIdentifier ?? "",
            title: title ?? "",
            notes: item.notes,
            location: item.location,
            url: item.url,
            start: start,
            end: endDate ?? start,
            isAllDay: item.isAllDay,
            occurrenceDate: occurrence ?? start,
            isRecurring: item.hasRecurrenceRules,
            repeatRule: rule,
            isDetached: item.isDetached
        )
    }
}
