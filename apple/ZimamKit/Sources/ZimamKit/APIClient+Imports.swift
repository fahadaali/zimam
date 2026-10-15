import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// `/v1/imports` (api/DEVELOPMENT.md, «الاستيراد»).
public extension APIClient {
    /// `GET /v1/imports/sources`: the sources and the upload limit.
    func importSources() async throws -> ImportSources {
        try await getJSON("v1/imports/sources")
    }

    /// `POST /v1/imports` with a file (multipart). 202 with the queued job; refused with
    /// `file_too_large` (413), `invalid_file_type`, `empty_file` (400) or `import_in_progress` (409).
    func startImport(source: String, fileName: String, data: Data) async throws -> ImportJob {
        var form = MultipartForm()
        form.addField("source", source)
        form.addFile("file", fileName: fileName, mimeType: MultipartForm.mimeType(forFileName: fileName), data: data)
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/imports"))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data
        return try Self.decodeJob(try await perform(request))
    }

    /// `POST /v1/imports` with a personal token (Todoist). The token is sent once, in this request
    /// only; neither the app nor the server keeps it.
    func startImport(source: String, token: String) async throws -> ImportJob {
        struct Body: Encodable {
            let source: String
            let token: String
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/imports"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(source: source, token: token))
        return try Self.decodeJob(try await perform(request))
    }

    /// `GET /v1/imports/oauth/:source/start?return=app`: the provider's page to open in
    /// ASWebAuthenticationSession. Its callback returns to `zimam://import-callback` (`ImportCallback`).
    /// Refused with `source_unavailable` (503), `import_in_progress` (409) or `pro_required` (403).
    func startOAuthImport(source: String) async throws -> URL {
        struct Response: Decodable { let url: String }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/imports/oauth/\(source)/start"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "return", value: "app")]
        guard let requestURL = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        let response = try JSONDecoder().decode(Response.self, from: try await perform(request))
        guard let url = URL(string: response.url), url.scheme == "https" else { throw URLError(.badServerResponse) }
        return url
    }

    /// `POST /v1/imports/oauth/confirm`: starts the import a provider's callback left waiting
    /// (`ImportCallback.pending`), once the user has agreed to import into this account. `token`
    /// is Trello's, from the callback's fragment; sent once, kept nowhere. 202 with the queued job;
    /// refused with `not_found` (404: expired and swept, or another account's), `expired` (410),
    /// `invalid_token` (400), `pro_required` (403), `import_in_progress` (409),
    /// `exchange_failed` (502) or `import_unavailable` (503).
    func confirmOAuthImport(pending: String, token: String?) async throws -> ImportJob {
        struct Body: Encodable {
            let pending: String
            let token: String?
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/imports/oauth/confirm"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(pending: pending, token: token))
        return try Self.decodeJob(try await perform(request))
    }

    /// `GET /v1/imports`: the latest twenty, newest first.
    func imports() async throws -> [ImportJob] {
        struct Response: Decodable { let jobs: [ImportJob] }
        let response: Response = try await getJSON("v1/imports")
        return response.jobs
    }

    /// `GET /v1/imports/:id`: status, progress, counts, warnings and errors.
    func importJob(id: String) async throws -> ImportJob {
        // A UUID: nothing in it needs escaping in a path.
        try Self.decodeJob(try await perform(URLRequest(url: baseURL.appendingPathComponent("v1/imports/\(id)"))))
    }

    private func getJSON<Response: Decodable>(_ path: String) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        return try JSONDecoder().decode(Response.self, from: try await perform(request))
    }

    /// `{ job }`, as `POST /v1/imports` and `GET /v1/imports/:id` answer.
    internal static func decodeJob(_ data: Data) throws -> ImportJob {
        struct Response: Decodable { let job: ImportJob }
        return try JSONDecoder().decode(Response.self, from: data).job
    }
}
