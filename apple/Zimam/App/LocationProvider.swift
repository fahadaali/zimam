import CoreLocation
import Foundation
import Observation
import ZimamKit
#if canImport(UIKit)
import UIKit
#endif

/// The place prayer times are computed for. Asks for the location when the user taps
/// «استعمال موقعي الحالي» (when in use, until the first reading), and keeps the last coordinate
/// on the device. It reaches the server only, rounded to city level, when the user turns on
/// sharing in settings (see `SessionStore.sharePlace`).
///
/// The reading uses `startUpdatingLocation` and stops at the first fix, rather than the one-shot
/// `requestLocation`: that one gives up with `kCLErrorLocationUnknown` when the first fix is slow
/// (right after the permission prompt, indoors, or in the Simulator before a location is set),
/// while continuous updates keep trying until the timeout below.
@MainActor
@Observable
final class LocationProvider {
    struct Coordinate: Equatable {
        let latitude: Double
        let longitude: Double
    }

    private(set) var coordinate: Coordinate? = nil
    /// True while a reading is running (not while the permission prompt is up).
    private(set) var isLocating = false
    private(set) var errorMessage: String? = nil
    /// Kept here, not read from the manager, so views showing «فتح إعدادات النظام» update.
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// «الموقع الدقيق» is on for Zimam. Location reminders need it: the system does not watch
    /// places for an app that has only the approximate location.
    private(set) var isPrecise = true
    /// Called when a new coordinate is saved.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// Called when the permission or its precision changes, so location reminders are rescheduled.
    @ObservationIgnored var onAuthorizationChange: (@MainActor () -> Void)?

    private let manager = CLLocationManager()
    private let delegate = LocationDelegate()
    @ObservationIgnored private var waitingForPermission = false
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// How long a reading may take before the user is told it failed.
    private static let readingTimeout: Duration = .seconds(20)
    private static let deniedMessage = "لا يصل زمام إلى موقعك. اسمح له بالموقع من إعدادات النظام، أو فعّل خدمات الموقع."
    private static let failedMessage = "تعذّر تحديد موقعك. تحقّق من تفعيل خدمات الموقع وحاول مرة أخرى."

    init() {
        // Saved in the App Group, so the large widget can find the next prayer.
        if let saved = SharedSettings.coordinate() {
            coordinate = Coordinate(latitude: saved.latitude, longitude: saved.longitude)
        }
        authorization = manager.authorizationStatus
        isPrecise = manager.accuracyAuthorization == .fullAccuracy
        // City level is enough for prayer times, and quicker to get than a precise fix.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = delegate
        delegate.onLocation = { [weak self] latitude, longitude in
            self?.received(latitude: latitude, longitude: longitude)
        }
        delegate.onFailure = { [weak self] code in
            self?.failed(code)
        }
        delegate.onAuthorizationChange = { [weak self] status in
            self?.authorizationChanged(status)
        }
    }

    /// The user (or a policy) turned location off for Zimam, or Location Services are off.
    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// The user has not answered the location prompt yet.
    var isUndecided: Bool {
        authorization == .notDetermined
    }

    /// Whether location reminders can fire on this device: iPhone and iPad, with location allowed
    /// while using the app (enough for location notification triggers) and precise. The Mac has
    /// no location notification triggers. With «دائماً» the app watches places itself
    /// (`canMonitorPlaces`).
    var canWatchPlaces: Bool {
        #if os(iOS)
        (authorization == .authorizedWhenInUse || authorization == .authorizedAlways) && isPrecise
        #else
        false
        #endif
    }

    /// Whether the app itself watches places (`PlaceMonitor`): iPhone and iPad with location
    /// «دائماً» and precise. Then a place and a time on one reminder take each other back.
    var canMonitorPlaces: Bool {
        #if os(iOS)
        authorization == .authorizedAlways && isPrecise
        #else
        false
        #endif
    }

    /// Location is allowed only while using the app, and iOS may still show the one prompt that
    /// upgrades it to «دائماً». After that prompt, only System Settings can change it.
    var canAskForAlways: Bool {
        #if os(iOS)
        authorization == .notDetermined
            || (authorization == .authorizedWhenInUse && !UserDefaults.standard.bool(forKey: Self.askedAlwaysKey))
        #else
        false
        #endif
    }

    /// Allowed while using the app, but not «دائماً»: location reminders still fire, but a place
    /// and a time on the same reminder cannot take each other back.
    var needsAlways: Bool {
        #if os(iOS)
        authorization == .authorizedWhenInUse
        #else
        false
        #endif
    }

    private static let askedAlwaysKey = "location.askedAlways"

    /// Asks for location while using the app, without reading it: the first location reminder
    /// needs it to fire. Does nothing once the user has answered.
    func requestAuthorization() {
        authorization = manager.authorizationStatus
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Asks for location «دائماً», after the app has explained why (`AlwaysLocationCard`). Undecided,
    /// iOS first offers «أثناء الاستخدام» and asks about «دائماً» later on its own; allowed while
    /// using, it shows its one upgrade prompt. Location never leaves the device for this.
    func requestAlwaysAuthorization() {
        #if os(iOS)
        authorization = manager.authorizationStatus
        guard canAskForAlways else { return }
        if authorization == .authorizedWhenInUse {
            UserDefaults.standard.set(true, forKey: Self.askedAlwaysKey)
        }
        manager.requestAlwaysAuthorization()
        #endif
    }

    /// Prayer times for the saved place, or nil before the first location.
    func schedule(method: PrayerMethod) -> PrayerSchedule? {
        guard let coordinate else { return nil }
        return PrayerSchedule(latitude: coordinate.latitude, longitude: coordinate.longitude, method: method, timeZone: .current)
    }

    /// Asks for permission if needed, then reads the location once.
    func requestLocation() {
        guard !isLocating else { return }
        errorMessage = nil
        authorization = manager.authorizationStatus
        switch authorization {
        case .notDetermined:
            // The reading starts from `authorizationChanged` once the user answers. Tapping
            // again while the prompt is up just asks again; the system shows one prompt.
            waitingForPermission = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = Self.deniedMessage
        default:
            // .authorizedWhenInUse on iPhone and iPad, .authorizedAlways on the Mac.
            startReading()
        }
    }

    /// The page in System Settings where the user can allow location for Zimam.
    static var systemSettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        #endif
    }

    // MARK: Reading

    private func startReading() {
        isLocating = true
        manager.startUpdatingLocation()
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.readingTimeout)
            guard !Task.isCancelled else { return }
            self?.stopReading(message: Self.failedMessage)
        }
    }

    private func stopReading(message: String?) {
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        isLocating = false
        errorMessage = message
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        isPrecise = manager.accuracyAuthorization == .fullAccuracy
        onAuthorizationChange?()
        switch status {
        case .notDetermined:
            return
        case .denied, .restricted:
            let wasAsking = waitingForPermission || isLocating
            waitingForPermission = false
            if wasAsking { stopReading(message: Self.deniedMessage) }
        default:
            if waitingForPermission {
                waitingForPermission = false
                startReading()
            }
        }
    }

    private func received(latitude: Double, longitude: Double) {
        guard isLocating else { return }
        stopReading(message: nil)
        coordinate = Coordinate(latitude: latitude, longitude: longitude)
        SharedSettings.saveCoordinate(SharedSettings.Coordinate(latitude: latitude, longitude: longitude))
        ZimamShared.reloadWidgets()
        onChange?()
    }

    private func failed(_ code: CLError.Code?) {
        guard isLocating else { return }
        switch code {
        case .some(.locationUnknown):
            // No fix yet; Core Location keeps trying until the timeout.
            return
        case .some(.denied):
            authorization = manager.authorizationStatus
            stopReading(message: Self.deniedMessage)
        default:
            stopReading(message: Self.failedMessage)
        }
    }
}

/// CoreLocation's delegate, kept apart so the observable provider stays a plain class.
/// The manager is created on the main thread, so its callbacks arrive there; they still hop
/// to the main actor explicitly.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocation: (@MainActor (Double, Double) -> Void)?
    var onFailure: (@MainActor (CLError.Code?) -> Void)?
    var onAuthorizationChange: (@MainActor (CLAuthorizationStatus) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // A negative accuracy marks an invalid reading.
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let handler = onLocation
        Task { @MainActor in handler?(latitude, longitude) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let handler = onFailure
        Task { @MainActor in handler?(code) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let handler = onAuthorizationChange
        Task { @MainActor in handler?(status) }
    }
}
