import CoreLocation
import Foundation
import Observation
import ZimamKit

/// The place prayer times are computed for. Asks for the location once when
/// the user taps «استعمال موقعي الحالي» (when in use, one reading), and keeps
/// the last coordinate on the device only.
@MainActor
@Observable
final class LocationProvider {
    struct Coordinate: Equatable {
        let latitude: Double
        let longitude: Double
    }

    private(set) var coordinate: Coordinate? = nil
    private(set) var isLocating = false
    private(set) var errorMessage: String? = nil
    /// Called when a new coordinate is saved.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    private let manager = CLLocationManager()
    private let delegate = LocationDelegate()
    @ObservationIgnored private var waitingForPermission = false

    private static let latitudeKey = "location.latitude"
    private static let longitudeKey = "location.longitude"
    private static let deniedMessage = "لا يصل زمام إلى موقعك. اسمح له من إعدادات النظام لحساب أوقات الصلاة."
    private static let failedMessage = "تعذّر تحديد موقعك. حاول مرة أخرى."

    init() {
        let defaults = UserDefaults.standard
        if let latitude = defaults.object(forKey: Self.latitudeKey) as? Double,
           let longitude = defaults.object(forKey: Self.longitudeKey) as? Double {
            coordinate = Coordinate(latitude: latitude, longitude: longitude)
        }
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = delegate
        delegate.onLocation = { [weak self] latitude, longitude in
            self?.received(latitude: latitude, longitude: longitude)
        }
        delegate.onFailure = { [weak self] in
            self?.failed()
        }
        delegate.onAuthorizationChange = { [weak self] in
            self?.authorizationChanged()
        }
    }

    var isDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Prayer times for the saved place, or nil before the first location.
    func schedule(method: PrayerMethod) -> PrayerSchedule? {
        guard let coordinate else { return nil }
        return PrayerSchedule(latitude: coordinate.latitude, longitude: coordinate.longitude, method: method, timeZone: .current)
    }

    /// Asks for permission if needed, then reads the location once.
    func requestLocation() {
        errorMessage = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            waitingForPermission = true
            isLocating = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = Self.deniedMessage
        default:
            isLocating = true
            manager.requestLocation()
        }
    }

    private func authorizationChanged() {
        guard waitingForPermission else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            return
        case .denied, .restricted:
            waitingForPermission = false
            isLocating = false
            errorMessage = Self.deniedMessage
        default:
            waitingForPermission = false
            manager.requestLocation()
        }
    }

    private func received(latitude: Double, longitude: Double) {
        isLocating = false
        errorMessage = nil
        coordinate = Coordinate(latitude: latitude, longitude: longitude)
        UserDefaults.standard.set(latitude, forKey: Self.latitudeKey)
        UserDefaults.standard.set(longitude, forKey: Self.longitudeKey)
        onChange?()
    }

    private func failed() {
        isLocating = false
        errorMessage = isDenied ? Self.deniedMessage : Self.failedMessage
    }
}

/// CoreLocation's delegate, kept apart so the observable provider stays a plain class.
/// Callbacks hop to the main actor.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocation: (@MainActor (Double, Double) -> Void)?
    var onFailure: (@MainActor () -> Void)?
    var onAuthorizationChange: (@MainActor () -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        let handler = onLocation
        Task { @MainActor in handler?(latitude, longitude) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let handler = onFailure
        Task { @MainActor in handler?() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let handler = onAuthorizationChange
        Task { @MainActor in handler?() }
    }
}
