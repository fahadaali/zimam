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

    public var isUnauthorized: Bool { status == 401 }
}

public struct SignInResponse: Decodable, Sendable {
    public let token: String
    public let user: User
}

/// Talks to the Zimam API (api/). Every call after sign-in sends the session token.
public final class APIClient: @unchecked Sendable {
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
    public func pull(cursor: Int64, limit: Int = 500) async throws -> PullResponse {
        try await send("GET", "v1/sync", query: [URLQueryItem(name: "cursor", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit))])
    }

    /// Sends up to `maxPushBatch` edits; each comes back with its own result, in order.
    public func push(_ mutations: [Mutation]) async throws -> [MutationResult] {
        struct Body: Encodable { let mutations: [Mutation] }
        struct Response: Decodable { let results: [MutationResult] }
        let response: Response = try await send("POST", "v1/sync", body: Body(mutations: mutations))
        return response.results
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

    private struct Empty: Decodable {}
    private struct NoBody: Encodable {}
    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String
            let message: String
        }
        let error: Detail
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await send(method, path, query: query, body: Optional<NoBody>.none)
    }

    private func send<Response: Decodable, Body: Encodable>(
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
            throw APIError(status: status, code: detail?.code ?? "http_\(status)", message: detail?.message ?? "")
        }
        if Response.self == Empty.self || data.isEmpty { return try JSONDecoder().decode(Response.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
