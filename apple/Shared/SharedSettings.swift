import Foundation
import ZimamKit

/// The account (for its calendar and prayer method) and the place for prayer times,
/// kept in the App Group so the widgets and intents read what the app saved. UserDefaults is
/// safe from any thread, so this is not tied to the main actor.
nonisolated enum SharedSettings {
    private static let userKey = "session.user"
    private static let latitudeKey = "location.latitude"
    private static let longitudeKey = "location.longitude"
    private static let placeNameKey = "location.name"
    private static let manualKey = "location.manual"

    struct Coordinate: Equatable {
        let latitude: Double
        let longitude: Double
    }

    /// The signed-in account as last saved by the app, or nil when signed out.
    static func user() -> User? {
        guard let data = ZimamShared.defaults.data(forKey: userKey) else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    static func saveUser(_ user: User?) {
        if let user, let data = try? JSONEncoder().encode(user) {
            ZimamShared.defaults.set(data, forKey: userKey)
        } else {
            ZimamShared.defaults.removeObject(forKey: userKey)
        }
    }

    /// The last place the user chose for prayer times. It stays on the device.
    static func coordinate() -> Coordinate? {
        let defaults = ZimamShared.defaults
        guard let latitude = defaults.object(forKey: latitudeKey) as? Double,
              let longitude = defaults.object(forKey: longitudeKey) as? Double else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// Saves the place with its name («الرياض»), if known. `manual` is a place picked on the map,
    /// which the device's location no longer moves.
    static func saveCoordinate(_ coordinate: Coordinate, name: String? = nil, manual: Bool = false) {
        let defaults = ZimamShared.defaults
        defaults.set(coordinate.latitude, forKey: latitudeKey)
        defaults.set(coordinate.longitude, forKey: longitudeKey)
        defaults.set(manual, forKey: manualKey)
        if let name { defaults.set(name, forKey: placeNameKey) } else { defaults.removeObject(forKey: placeNameKey) }
    }

    /// The saved place's name, once known.
    static func placeName() -> String? {
        ZimamShared.defaults.string(forKey: placeNameKey)
    }

    static func savePlaceName(_ name: String?) {
        if let name { ZimamShared.defaults.set(name, forKey: placeNameKey) } else { ZimamShared.defaults.removeObject(forKey: placeNameKey) }
    }

    /// True when the place was picked on the map rather than read from the device.
    static func isManualPlace() -> Bool {
        ZimamShared.defaults.bool(forKey: manualKey)
    }

    /// Prayer times for the saved place with the user's method and madhab, or nil before the first location.
    static func prayerSchedule() -> PrayerSchedule? {
        guard let coordinate = coordinate() else { return nil }
        let settings = user()?.settings
        return PrayerSchedule(latitude: coordinate.latitude, longitude: coordinate.longitude,
                              method: settings?.prayerMethod ?? .ummAlQura, madhab: settings?.asrMadhab ?? .shafi,
                              timeZone: .current)
    }

    /// Copies what earlier versions kept in the app's own defaults into the App Group, once.
    /// Called by the app at launch, before anything reads these settings.
    static func migrateFromStandardDefaults() {
        let shared = ZimamShared.defaults
        let standard = UserDefaults.standard
        guard shared !== standard else { return }
        for key in [userKey, latitudeKey, longitudeKey] where shared.object(forKey: key) == nil {
            if let value = standard.object(forKey: key) {
                shared.set(value, forKey: key)
            }
        }
    }
}
