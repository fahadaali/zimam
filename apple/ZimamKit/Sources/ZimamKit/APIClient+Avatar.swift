import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The account's photo («صورة العرض», api/DEVELOPMENT.md). `User.avatarVersion` says when it last
// changed, so the app downloads it again only then.
public extension APIClient {
    /// `PUT /v1/me/avatar`: a JPEG (the app sends a 512 px square), up to `maxAvatarBytes`.
    func uploadAvatar(jpeg data: Data) async throws -> User {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/me/avatar"))
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try JSONDecoder().decode(User.self, from: try await perform(request))
    }

    /// `GET /v1/me/avatar`: the photo's bytes.
    func avatar() async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/me/avatar"))
        request.httpMethod = "GET"
        return try await perform(request)
    }

    /// `DELETE /v1/me/avatar`.
    func deleteAvatar() async throws -> User {
        try await send("DELETE", "v1/me/avatar")
    }

    /// What the server accepts (`MAX_AVATAR_BYTES` in api/src/routes/me.ts).
    static let maxAvatarBytes = 1024 * 1024
}
