import CoreLocation
import Foundation
import Observation

// MARK: Current location

/// Reads the current position once, precisely, for a location reminder's place. Kept apart from
/// `LocationProvider`, whose city-level reading sets the place for prayer times: choosing a place
/// for a reminder must not move the prayer times. Asks for location while using the app the
/// first time; the reading stops at the first fix within `goodAccuracy`, or at the timeout with
/// the best one so far.
@MainActor
@Observable
final class CurrentPlaceReader {
    private(set) var isReading = false
    private(set) var errorMessage: String?
    private(set) var isDenied = false
    /// The last position read, to search near it.
    private(set) var coordinate: (Double, Double)?
    @ObservationIgnored var onPlace: (@MainActor (Double, Double) -> Void)?

    private let manager = CLLocationManager()
    private let delegate = PlaceReaderDelegate()
    @ObservationIgnored private var waitingForPermission = false
    @ObservationIgnored private var best: (latitude: Double, longitude: Double, accuracy: Double)?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// Meters; a fix this good ends the reading early.
    private static let goodAccuracy: Double = 50
    private static let readingTimeout: Duration = .seconds(15)
    private static let deniedMessage = "لا يصل زمام إلى موقعك. اسمح له بالموقع من إعدادات النظام، أو ابحث عن المكان."
    private static let failedMessage = "تعذّر تحديد موقعك. ابحث عن المكان بدلاً منه."

    init() {
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.delegate = delegate
        delegate.onLocation = { [weak self] latitude, longitude, accuracy in
            self?.received(latitude: latitude, longitude: longitude, accuracy: accuracy)
        }
        delegate.onFailure = { [weak self] code in
            self?.failed(code)
        }
        delegate.onAuthorizationChange = { [weak self] status in
            self?.authorizationChanged(status)
        }
    }

    func read() {
        guard !isReading else { return }
        errorMessage = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            waitingForPermission = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            isDenied = true
            errorMessage = Self.deniedMessage
        default:
            start()
        }
    }

    private func start() {
        isReading = true
        best = nil
        manager.startUpdatingLocation()
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.readingTimeout)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        isReading = false
        if let best {
            coordinate = (best.latitude, best.longitude)
            onPlace?(best.latitude, best.longitude)
        } else {
            errorMessage = Self.failedMessage
        }
    }

    private func received(latitude: Double, longitude: Double, accuracy: Double) {
        guard isReading else { return }
        if best == nil || accuracy < (best?.accuracy ?? .infinity) {
            best = (latitude, longitude, accuracy)
        }
        if accuracy <= Self.goodAccuracy { finish() }
    }

    private func failed(_ code: CLError.Code?) {
        guard isReading else { return }
        switch code {
        case .some(.locationUnknown):
            return
        case .some(.denied):
            best = nil
            isDenied = true
            finish()
            errorMessage = Self.deniedMessage
        default:
            finish()
        }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            return
        case .denied, .restricted:
            isDenied = true
            if waitingForPermission {
                waitingForPermission = false
                errorMessage = Self.deniedMessage
            }
        default:
            isDenied = false
            if waitingForPermission {
                waitingForPermission = false
                start()
            }
        }
    }
}

/// CoreLocation's delegate for `CurrentPlaceReader`; its callbacks hop to the main actor, and
/// it is not tied to it, so a call from another thread cannot stop the app.
nonisolated private final class PlaceReaderDelegate: NSObject, CLLocationManagerDelegate {
    var onLocation: (@MainActor (Double, Double, Double) -> Void)?
    var onFailure: (@MainActor (CLError.Code?) -> Void)?
    var onAuthorizationChange: (@MainActor (CLAuthorizationStatus) -> Void)?

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // A negative accuracy marks an invalid reading.
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let accuracy = location.horizontalAccuracy
        let handler = onLocation
        Task { @MainActor in handler?(latitude, longitude, accuracy) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let handler = onFailure
        Task { @MainActor in handler?(code) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let handler = onAuthorizationChange
        Task { @MainActor in handler?(status) }
    }
}
