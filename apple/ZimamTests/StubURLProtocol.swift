import Foundation
import Synchronization
import ZimamKit

/// Answers every request of `StubURLProtocol.session()` without the network: with what the test
/// registered for its path (`respond(to:method:with:status:)`), else `{"members": [serverMember]}`.
/// Each answer waits until the test calls `release(_:method:)` for its path, so a test can change
/// things while the request is in flight; `waitForRequest(to:method:)` waits until it arrives.
/// Requests are counted and recorded (URL and body) by path, and by method and path, since
/// `GET /v1/sync` (pull) and `POST /v1/sync` (push) share one path.
/// URLSession runs `startLoading` off the main thread, so waiting there never blocks the tests.
nonisolated final class StubURLProtocol: URLProtocol {
    static let serverMember = ProjectMember(
        userId: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, name: "فهد", role: .owner, addedAt: 1_760_000_000_000
    )

    /// An answer a test registered.
    nonisolated struct Canned: Sendable {
        let body: Data
        let status: Int
    }

    /// A request as it arrived.
    nonisolated struct Recorded: Sendable {
        let url: URL
        let body: Data?
    }

    nonisolated struct State {
        var requests: [String: Int] = [:]
        var released: Set<String> = []
        /// Answers in the order registered; the last one stays for the requests after it.
        var answers: [String: [Canned]] = [:]
        var recorded: [String: [Recorded]] = [:]
    }

    private static let state = Mutex(State())
    private static let membersBody: Data = try! JSONEncoder().encode(["members": [serverMember]])
    /// How long an unreleased request waits before answering anyway, so a failing test never hangs.
    private static let timeout: TimeInterval = 5

    /// A session whose requests all come here.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The key for a request: its path in lower case ("/v1/projects/<id>/members"), after its
    /// method when one is given ("POST /v1/sync"). Without a method, a key covers every method.
    static func key(_ path: String, method: String? = nil) -> String {
        guard let method else { return path.lowercased() }
        return "\(method.uppercased()) \(path.lowercased())"
    }

    static func requestCount(for path: String, method: String? = nil) -> Int {
        state.withLock { $0.requests[key(path, method: method), default: 0] }
    }

    /// The requests to `path` (with `method`, if given) so far, oldest first.
    static func recordedRequests(to path: String, method: String? = nil) -> [Recorded] {
        state.withLock { $0.recorded[key(path, method: method), default: []] }
    }

    /// Answers the requests to `path` (with `method`, if given) with `body` and `status`. Registered
    /// again, the answers go out in order, one per request; the last one keeps answering. An answer
    /// for the method wins over one for the whole path.
    static func respond(to path: String, method: String? = nil, with body: Data, status: Int = 200) {
        state.withLock { $0.answers[key(path, method: method), default: []].append(Canned(body: body, status: status)) }
    }

    /// Lets the requests to `path` (with `method`, if given) answer, now and later.
    static func release(_ path: String, method: String? = nil) {
        state.withLock { _ = $0.released.insert(key(path, method: method)) }
    }

    /// Forgets `path` for every method: its requests, its release and its answers. Each suite uses
    /// its own paths (the members tests one per project), so this never touches another suite's.
    static func reset(_ path: String) {
        let target = key(path)
        func matches(_ key: String) -> Bool { key == target || key.hasSuffix(" " + target) }
        state.withLock { state in
            state.requests = state.requests.filter { !matches($0.key) }
            state.released = state.released.filter { !matches($0) }
            state.answers = state.answers.filter { !matches($0.key) }
            state.recorded = state.recorded.filter { !matches($0.key) }
        }
    }

    /// Returns once a request to `path` (with `method`, if given) has arrived; throws after a few
    /// seconds without one.
    static func waitForRequest(to path: String, method: String? = nil) async throws {
        for _ in 0..<500 {
            if requestCount(for: path, method: method) > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = Self.key(url.path)
        let exact = Self.key(url.path, method: request.httpMethod ?? "GET")
        let recorded = Recorded(url: url, body: Self.bodyData(of: request))
        Self.state.withLock { state in
            for key in [path, exact] {
                state.requests[key, default: 0] += 1
                state.recorded[key, default: []].append(recorded)
            }
        }

        let deadline = Date().addingTimeInterval(Self.timeout)
        while !Self.state.withLock({ $0.released.contains(path) || $0.released.contains(exact) }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let answer: Canned = Self.state.withLock { state in
            for key in [exact, path] {
                guard let queue = state.answers[key], let first = queue.first else { continue }
                if queue.count > 1 { state.answers[key] = Array(queue.dropFirst()) }
                return first
            }
            return Canned(body: Self.membersBody, status: 200)
        }

        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The request's body. URLSession often hands a protocol the body as a stream, not `httpBody`.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
