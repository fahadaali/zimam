import Foundation
import Synchronization
import ZimamKit

/// Answers every request of `StubURLProtocol.session()` with `{"members": [serverMember]}`, without
/// the network. Each answer waits until the test calls `release(_:)` for its path, so a test can
/// change things while the request is in flight; `waitForRequest(to:)` waits until it arrives.
/// URLSession runs `startLoading` off the main thread, so waiting there never blocks the tests.
nonisolated final class StubURLProtocol: URLProtocol {
    static let serverMember = ProjectMember(
        userId: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, name: "فهد", role: .owner, addedAt: 1_760_000_000_000
    )

    nonisolated struct State {
        var requests: [String: Int] = [:]
        var released: Set<String> = []
    }

    private static let state = Mutex(State())
    private static let body: Data = try! JSONEncoder().encode(["members": [serverMember]])
    /// How long an unreleased request waits before answering anyway, so a failing test never hangs.
    private static let timeout: TimeInterval = 5

    /// A session whose requests all come here.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The key for a request: its path in lower case ("/v1/projects/<id>/members").
    static func key(_ path: String) -> String { path.lowercased() }

    static func requestCount(for path: String) -> Int {
        state.withLock { $0.requests[key(path), default: 0] }
    }

    /// Lets the requests to `path` answer, now and later.
    static func release(_ path: String) {
        state.withLock { _ = $0.released.insert(key(path)) }
    }

    /// Returns once a request to `path` has arrived; throws after a few seconds without one.
    static func waitForRequest(to path: String) async throws {
        for _ in 0..<500 {
            if requestCount(for: path) > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = Self.key(url.path)
        Self.state.withLock { $0.requests[path, default: 0] += 1 }

        let deadline = Date().addingTimeInterval(Self.timeout)
        while !Self.state.withLock({ $0.released.contains(path) }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
