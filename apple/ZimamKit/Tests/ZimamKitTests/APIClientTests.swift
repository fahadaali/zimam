import Foundation
import Testing
@testable import ZimamKit

/// The bodies `APIClient` sends and the error fields it reads, in the server's shape (api/src).
struct APIClientTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }

    @Test func deleteAccountSendsAFreshAppleSignIn() throws {
        let body = try json(APIClient.deleteAccountBody(.apple(identityToken: "id-token", nonce: "raw-nonce", authorizationCode: "code")))
        #expect(body["provider"] as? String == "apple")
        #expect(body["identityToken"] as? String == "id-token")
        #expect(body["nonce"] as? String == "raw-nonce")
        #expect(body["authorizationCode"] as? String == "code")
        #expect(body["idToken"] == nil)

        let withoutCode = try json(APIClient.deleteAccountBody(.apple(identityToken: "id-token", nonce: "raw-nonce", authorizationCode: nil)))
        #expect(withoutCode["authorizationCode"] == nil)
        #expect(Set(withoutCode.keys) == ["provider", "identityToken", "nonce"])
    }

    @Test func deleteAccountSendsAFreshGoogleSignIn() throws {
        let body = try json(APIClient.deleteAccountBody(.google(idToken: "google-token", nonce: "raw-nonce")))
        #expect(Set(body.keys) == ["provider", "idToken", "nonce"])
        #expect(body["provider"] as? String == "google")
        #expect(body["idToken"] as? String == "google-token")
        #expect(body["nonce"] as? String == "raw-nonce")
    }

    @Test func deviceScheduleIsUnixMillisecondsOrNull() throws {
        let date = Date(timeIntervalSince1970: 1_791_882_000.1234) // 2026-10-13T09:00:00.123Z
        let body = try json(APIClient.deviceScheduleBody(date))
        #expect((body["scheduledThrough"] as? NSNumber)?.int64Value == 1_791_882_000_123)

        // Null, not left out: the whole local window.
        let whole = try json(APIClient.deviceScheduleBody(nil))
        #expect(whole.keys.contains("scheduledThrough"))
        #expect(whole["scheduledThrough"] is NSNull)
    }

    @Test func decodesAssistantRateLimitAndBusyErrors() {
        let minute = APIClient.apiError(status: 429, data: Data(#"""
        {"error":{"code":"ai_rate_limited","message":"Too many requests","scope":"minute","limit":10,"retryAfter":42}}
        """#.utf8))
        #expect(minute == APIError(status: 429, code: "ai_rate_limited", message: "Too many requests", limit: 10,
                                   retryAfter: 42, scope: "minute"))

        let busy = APIClient.apiError(status: 503, data: Data(#"{"error":{"code":"ai_busy","message":"Busy","retryAfter":5}}"#.utf8))
        #expect(busy.code == "ai_busy")
        #expect(busy.retryAfter == 5)
        #expect(busy.scope == nil)
        #expect(busy.limit == nil)

        let quota = APIClient.apiError(status: 429, data: Data(#"""
        {"error":{"code":"ai_quota_exceeded","message":"limit","limit":300,"resetsOn":"2026-11-01","plan":"free"}}
        """#.utf8))
        #expect(quota.limit == 300)
        #expect(quota.resetsOn == "2026-11-01")
        #expect(quota.retryAfter == nil)
    }

    @Test func anErrorWithoutABodyIsNamedByItsStatus() {
        let error = APIClient.apiError(status: 502, data: Data("<html>".utf8))
        #expect(error == APIError(status: 502, code: "http_502", message: ""))
    }
}
