import Foundation
import WidgetKit
import ZimamKit

/// The place and the calculation for prayer times, as the prayer widgets need them. On the iPhone,
/// iPad and Mac they come from the App Group (`SharedSettings`); the watch has no place of its
/// own, so the iPhone sends this over WatchConnectivity (`WatchPayload.prayerPlace`) and the watch
/// keeps it in its App Group (`WatchPrayerStore`).
nonisolated struct PrayerPlace: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var method: PrayerMethod
    var madhab: AsrMadhab
    /// «الرياض», when known.
    var name: String?

    var schedule: PrayerSchedule {
        PrayerSchedule(latitude: latitude, longitude: longitude, method: method, madhab: madhab, timeZone: .current)
    }
}

/// What the watch app received from the iPhone, for the watch's prayer complications and screen.
nonisolated enum WatchPrayerStore {
    private static let key = "prayer.place"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: GlanceStore.watchAppGroup) }

    static func read() -> PrayerPlace? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PrayerPlace.self, from: data)
    }

    /// Saves the place (nil forgets it); returns whether it changed, so callers reload only then.
    @discardableResult
    static func write(_ place: PrayerPlace?) -> Bool {
        guard let defaults, read() != place else { return false }
        if let place, let data = try? JSONEncoder().encode(place) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        return true
    }
}

/// One moment of a prayer widget: the countdown to the next prayer, or the time since the adhan
/// for half an hour after it (`PrayerClock`). Without a place it asks for one.
nonisolated struct PrayerEntry: TimelineEntry, Sendable {
    let date: Date
    let place: PrayerPlace?

    var state: PrayerClock.State? {
        place.flatMap { PrayerClock(schedule: $0.schedule).state(at: date) }
    }

    /// Whether the countdown shows hours (more than an hour to the adhan, «٨:٣١:٢٢»): too wide for
    /// the watch face's line above the clock and the corner's curve, which show the adhan's time
    /// instead («الفجر ٤:٤٢ ص») until the last hour. The timeline has an entry at that hour.
    var countdownHasHours: Bool {
        guard case .until(_, let time)? = state else { return false }
        return time.timeIntervalSince(date) > Self.hour
    }

    /// Whole minutes to the adhan (rounded up: «بعد ٤٢ د» until the 41st minute is reached) or since
    /// it (rounded down), for the one-line widgets; a new entry each minute near the adhan keeps it
    /// current. Nil without a place.
    var minutes: Int? {
        guard let state else { return nil }
        switch state {
        case .until(_, let time):
            return max(0, Int((time.timeIntervalSince(date) / 60 - Self.slack).rounded(.up)))
        case .since(_, let adhan):
            return max(0, Int((date.timeIntervalSince(adhan) / 60 + Self.slack).rounded(.down)))
        }
    }

    private static let hour: TimeInterval = 3600
    private static let minute: TimeInterval = 60
    /// Leeway for an entry that falls a hair off its minute.
    private static let slack = 0.001

    /// For the widget gallery: Mecca, with Umm al-Qura.
    static var placeholder: PrayerEntry {
        PrayerEntry(date: Date(), place: PrayerPlace(latitude: 21.4225, longitude: 39.8262, method: .ummAlQura,
                                                     madhab: .shafi, name: "مكة المكرمة"))
    }

    /// An entry now and at every change in the next day (each adhan, half an hour after it, and
    /// midnight), and each minute in the hour before each adhan and the half hour after it, for the
    /// one-line widgets' minutes (`minutes`, `countdownHasHours`); then a new timeline. The other
    /// sizes' countdown is the system's (`Text(_:style: .timer)`).
    static func timeline(place: PrayerPlace?, now: Date = Date()) -> Timeline<PrayerEntry> {
        guard let place else {
            return Timeline(entries: [PrayerEntry(date: now, place: nil)], policy: .never)
        }
        let clock = PrayerClock(schedule: place.schedule)
        let changes = clock.changes(from: now, days: 1)
        let end = changes.last ?? now.addingTimeInterval(hour)
        let adhans = Set(([now] + changes).compactMap { clock.state(at: $0)?.time })
        let before = Int(hour / minute)
        let after = Int(PrayerClock.elapsedWindow / minute)
        let minutes = adhans.flatMap { adhan in
            (-before...after).map { adhan.addingTimeInterval(Double($0) * minute) }
        }
        let dates = Array(Set([now] + changes + minutes.filter { $0 > now && $0 < end })).sorted()
        let entries = dates.map { PrayerEntry(date: $0, place: place) }
        return Timeline(entries: entries, policy: .after(end))
    }
}
