import Foundation
import Network
import Observation

/// Whether the device has a network path. The app works offline; only the assistant,
/// sharing and comments need the server, so they read this to hide or disable themselves.
/// A view that reads `isOnline` in its body updates when the connection changes.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true

    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.zimam.network"))
    }
}
