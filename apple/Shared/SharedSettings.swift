import Foundation
import ZimamKit

/// The account (for its calendar and prayer method) and the place for prayer times,
/// kept in the App Group so the widgets and intents read what the app saved. UserDefaults is
/// safe from any thread, so this is not tied to the main actor.
nonisolated enum SharedSettings {
    private static let userKey = "session.user"
    private static let latitudeKey = "location.latitude"
    private static let longitudeKey = "location.longitude"

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

    static func saveCoordinate(_ coordinate: Coordinate) {
        ZimamShared.defaults.set(coordinate.latitude, forKey: latitudeKey)
        ZimamShared.defaults.set(coordinate.longitude, forKey: longitudeKey)
    }

    /// Prayer times for the saved place with the user's method, or nil before the first location.
    static func prayerSchedule() -> PrayerSchedule? {
        guard let coordinate = coordinate() else { return nil }
        return PrayerSchedule(latitude: coordinate.latitude, longitude: coordinate.longitude,
                              method: user()?.settings.prayerMethod ?? .ummAlQura, timeZone: .current)
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
