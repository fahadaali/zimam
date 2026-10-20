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

    /// For the widget gallery: Mecca, with Umm al-Qura.
    static var placeholder: PrayerEntry {
        PrayerEntry(date: Date(), place: PrayerPlace(latitude: 21.4225, longitude: 39.8262, method: .ummAlQura,
                                                     madhab: .shafi, name: "مكة المكرمة"))
    }

    /// An entry now and at every change in the next day (each adhan, half an hour after it, and
    /// midnight); then a new timeline. The countdown itself is the system's (`Text(_:style: .timer)`).
    static func timeline(place: PrayerPlace?, now: Date = Date()) -> Timeline<PrayerEntry> {
        guard let place else {
            return Timeline(entries: [PrayerEntry(date: now, place: nil)], policy: .never)
        }
        let changes = PrayerClock(schedule: place.schedule).changes(from: now, days: 1)
        let entries = ([now] + changes).map { PrayerEntry(date: $0, place: place) }
        return Timeline(entries: entries, policy: .after(changes.last ?? now.addingTimeInterval(3600)))
    }
}
