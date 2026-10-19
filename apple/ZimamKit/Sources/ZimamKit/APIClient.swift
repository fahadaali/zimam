import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An error the API returned as `{ error: { code, message } }`, or a transport failure.
public struct APIError: Error, Equatable, Sendable {
    public let status: Int
    /// Stable English code, e.g. "unauthorized", "invalid".
    public let code: String
    public let message: String
    /// `429 ai_quota_exceeded` only: the monthly assistant limit.
    public var limit: Int?
    /// `429 ai_quota_exceeded` only: the day the quota resets, "2026-11-01".
    public var resetsOn: String?

    public var isUnauthorized: Bool { status == 401 }
}

public struct SignInResponse: Decodable, Sendable {
    public let token: String
    public let user: User
}

/// What the realtime socket says. It never carries data, only that something the user
/// can see changed up to a change-log sequence number; the app pulls if it is behind.
public enum RealtimeMessage {
    /// The server closes the socket with this code when its session ends (sign-out, account deletion).
    public static let signedOutCloseCode = 4001

    /// The seq of a `{"type":"changed","seq":N}` message, or nil for anything else ("pong").
    public static func changedSeq(_ text: String) -> Int64? {
        struct Message: Decodable {
            let type: String
            let seq: Int64?
        }
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)),
              message.type == "changed" else { return nil }
        return message.seq
    }
}

/// Talks to the Zimam API (api/). Every call after sign-in sends the session token.
public final class APIClient: Sendable {
    public static let maxPushBatch = 200

    public let baseURL: URL
    private let session: URLSession
    private let token: @Sendable () -> String?

    public init(baseURL: URL, session: URLSession = .shared, token: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

    /// Exchanges a Sign in with Apple identity token for a Zimam session.
    /// `nonce` is the raw value whose SHA-256 went into the Apple request. `authorizationCode`
    /// lets the server keep Apple's refresh token, which it revokes when the account is deleted.
    public func signInWithApple(
        identityToken: String, nonce: String?, name: String?, device: String?, authorizationCode: String? = nil
    ) async throws -> SignInResponse {
        struct Body: Encodable {
            let identityToken: String
            let nonce: String?
            let name: String?
            let device: String?
            let authorizationCode: String?
        }
        let body = Body(identityToken: identityToken, nonce: nonce, name: name, device: device, authorizationCode: authorizationCode)
        return try await send("POST", "v1/auth/apple", body: body)
    }

    /// Exchanges a Google ID token for a Zimam session (`POST /v1/auth/google`). `nonce` is the
    /// raw value whose SHA-256 (hex) went into the Google request. A first Google sign-in whose
    /// verified email matches an existing account joins it on the server.
    public func signInWithGoogle(idToken: String, nonce: String?, name: String?, device: String?) async throws -> SignInResponse {
        struct Body: Encodable {
            let idToken: String
            let nonce: String?
            let name: String?
            let device: String?
        }
        return try await send("POST", "v1/auth/google", body: Body(idToken: idToken, nonce: nonce, name: name, device: device))
    }

    public func signOut() async throws {
        let _: Empty = try await send("POST", "v1/auth/logout")
    }

    /// `DELETE /v1/me`: deletes the account and its data on the server, ends every session,
    /// and revokes Sign in with Apple. Shared projects the user owns pass to another member.
    public func deleteAccount() async throws {
        let _: Empty = try await send("DELETE", "v1/me")
    }

    public func me() async throws -> User {
        try await send("GET", "v1/me")
    }

    /// `PATCH /v1/me`: changes the name and/or settings; fields left nil stay as they are.
    public func updateMe(name: String? = nil, settings: User.Settings? = nil) async throws -> User {
        struct Body: Encodable {
            let name: String?
            let settings: User.Settings?
        }
        return try await send("PATCH", "v1/me", body: Body(name: name, settings: settings))
    }

    /// `GET /v1/tasks`: tasks the user can see, dated ones first by date and time. `status` is
    /// "todo", "doing", "done" or "open" (todo or doing); `dueFrom` and `dueTo` are inclusive
    /// days like "2026-10-15". Used by the watch, which keeps no local copy.
    public func listTasks(status: String? = nil, dueFrom: String? = nil, dueTo: String? = nil, limit: Int = 100) async throws -> [TaskRecord] {
        struct Response: Decodable { let tasks: [TaskRecord] }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        if let dueFrom { query.append(URLQueryItem(name: "dueFrom", value: dueFrom)) }
        if let dueTo { query.append(URLQueryItem(name: "dueTo", value: dueTo)) }
        let response: Response = try await send("GET", "v1/tasks", query: query)
        return response.tasks
    }

    /// Changes after `cursor`, oldest first. Repeat with the returned cursor while `hasMore`.
    /// `include=timeline`: projects shown as «المخطط الزمني» come as they are, which builds before
    /// it could not decode (the server sends them "list").
    public func pull(cursor: Int64, limit: Int = 500) async throws -> PullResponse {
        try await send("GET", "v1/sync", query: Self.pullQuery(cursor: cursor, limit: limit))
    }

    /// What this app asks the server for beyond what every app decodes: the "timeline" project
    /// view and saved places. A pull without them moves past their records, so when this list
    /// grows the app pulls once from the start (`SyncEngine`).
    public static let pullIncludes = "timeline,place"

    static func pullQuery(cursor: Int64, limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "cursor", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit)),
         URLQueryItem(name: "include", value: pullIncludes)]
    }

    /// Sends up to `maxPushBatch` edits; each comes back with its own result, in order.
    public func push(_ mutations: [Mutation]) async throws -> [MutationResult] {
        struct Body: Encodable { let mutations: [Mutation] }
        struct Response: Decodable { let results: [MutationResult] }
        let response: Response = try await send("POST", "v1/sync", body: Body(mutations: mutations))
        return response.results
    }

    // MARK: Realtime

    /// `GET /v1/realtime` as a WebSocket request (`wss`), signed in with the session token,
    /// or nil when signed out. The server only sends `{"type":"changed","seq":N}`; see `RealtimeMessage`.
    public func realtimeRequest() -> URLRequest? {
        guard let token = token() else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/realtime"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Push notifications

    public enum DevicePlatform: String, Encodable, Sendable {
        case ios, macos, watchos
    }

    /// The APNs environment the app was signed for: development builds use the sandbox.
    public enum PushEnvironment: String, Encodable, Sendable {
        case sandbox, production
    }

    /// `PUT /v1/devices/:token`: registers this install's APNs token (hex) for the session,
    /// so the server can push the reminders beyond the local notification window.
    public func registerDevice(token: String, platform: DevicePlatform, environment: PushEnvironment, bundleId: String) async throws {
        struct Body: Encodable {
            let platform: DevicePlatform
            let environment: PushEnvironment
            let bundleId: String
        }
        let _: Empty = try await send("PUT", "v1/devices/\(token)",
                                      body: Body(platform: platform, environment: environment, bundleId: bundleId))
    }

    /// `DELETE /v1/devices/:token`: stops pushes to this install. Called before signing out.
    public func unregisterDevice(token: String) async throws {
        let _: Empty = try await send("DELETE", "v1/devices/\(token)")
    }

    // MARK: Transport

    struct Empty: Decodable {}
    private struct NoBody: Encodable {}
    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String
            let message: String
            let limit: Int?
            let resetsOn: String?
        }
        let error: Detail
    }

    func send<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await send(method, path, query: query, body: Optional<NoBody>.none)
    }

    func send<Response: Decodable, Body: Encodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Body?
    ) async throws -> Response {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: data).error
            throw APIError(status: status, code: detail?.code ?? "http_\(status)", message: detail?.message ?? "",
                           limit: detail?.limit, resetsOn: detail?.resetsOn)
        }
        if Response.self == Empty.self || data.isEmpty { return try JSONDecoder().decode(Response.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// For requests built in other files (a multipart upload): adds the session token, sends,
    /// and returns the body of a 2xx answer; anything else throws `APIError`, as `send` does.
    func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: data).error
            throw APIError(status: status, code: detail?.code ?? "http_\(status)", message: detail?.message ?? "")
        }
        return data
    }
}
