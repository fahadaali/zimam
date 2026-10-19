import Foundation
import ZimamKit

/// Realtime sync: a WebSocket on which the server only says that something this user can
/// see changed (`{"type":"changed","seq":N}`). It never carries data; the change log and
/// `GET /v1/sync` stay the source of truth, so `SyncEngine` pulls when N is past its cursor.
/// Open only while the app is active and signed in; dropped connections come back with backoff.
@MainActor
final class RealtimeChannel {
    /// The server has changes up to this sequence number.
    var onChanged: (@MainActor (Int64) -> Void)?
    /// The socket came back after a drop (changes may have been missed), or the server ended
    /// the session: time for a full sync, which also signs out on a 401.
    var onResync: (@MainActor () -> Void)?

    private let api: APIClient
    private let session: URLSession
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    /// Keeps proxies from closing an idle socket; the server answers "pong" without waking up.
    private static let pingInterval: Duration = .seconds(30)

    init(api: APIClient, session: URLSession = .shared) {
        self.api = api
        self.session = session
    }

    func start() {
        guard loop == nil else { return }
        // The loop holds the channel while it runs (a weak capture would be held for the whole
        // run anyway). It ends with stop(), which SyncEngine calls in the background, on sign-out
        // and when the signed-in screen goes away, or on its own when signed out.
        loop = Task {
            await run()
            // Ended on its own (signed out): the next start() opens a new one.
            if !Task.isCancelled { loop = nil }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func run() async {
        var attempt = 0
        var connectedBefore = false
        while !Task.isCancelled {
            guard let request = api.realtimeRequest() else { return }
            let task = session.webSocketTask(with: request)
            socket = task
            task.resume()
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await task.send(.string("ping"))
                    try? await Task.sleep(for: Self.pingInterval)
                }
            }

            // The first "pong" shows the socket is open.
            var connected = false
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    if !connected {
                        connected = true
                        attempt = 0
                        if connectedBefore { onResync?() }
                        connectedBefore = true
                    }
                    if case .string(let text) = message, let seq = RealtimeMessage.changedSeq(text) {
                        onChanged?(seq)
                    }
                }
            } catch {
                // Closed, dropped, or refused (an ended session answers 401).
            }
            heartbeat.cancel()
            task.cancel(with: .goingAway, reason: nil)
            if socket === task { socket = nil }
            if Task.isCancelled { return }

            let status = (task.response as? HTTPURLResponse)?.statusCode
            if task.closeCode.rawValue == RealtimeMessage.signedOutCloseCode || status == 401 {
                onResync?()
                return
            }
            attempt += 1
            try? await Task.sleep(for: Self.delay(attempt: attempt))
        }
    }

    /// Doubles from about a second up to a minute, with jitter so devices do not reconnect together.
    private static func delay(attempt: Int) -> Duration {
        let ceiling = min(60_000, 1000 << min(attempt - 1, 6))
        return .milliseconds(Int(Double(ceiling) * Double.random(in: 0.5...1)))
    }
}
