import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Task attachments (api/DEVELOPMENT.md, «المرفقات»). They need the server; the app keeps
// the last list and the files it opened in its Caches folder only.
public extension APIClient {
    /// `GET /v1/tasks/:id/attachments`: oldest first, with the upload limit and whether this user may add.
    func attachments(on taskId: UUID) async throws -> TaskAttachments {
        try await send("GET", "v1/tasks/\(Self.path(taskId))/attachments")
    }

    /// `POST /v1/tasks/:id/attachments` (multipart). Refused with `file_too_large` or
    /// `storage_quota_exceeded` (413), `invalid_file_type` or `empty_file` (400), `forbidden`
    /// (a viewer) or `too_many_attachments` (409).
    func uploadAttachment(fileName: String, data: Data, to taskId: UUID) async throws -> TaskAttachment {
        var form = MultipartForm()
        form.addFile("file", fileName: fileName, mimeType: AttachmentRules.mimeType(forFileName: fileName), data: data)
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/tasks/\(Self.path(taskId))/attachments"))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data
        return try JSONDecoder().decode(TaskAttachment.self, from: try await perform(request))
    }

    /// `GET /v1/attachments/:id`: the file's bytes.
    func downloadAttachment(_ attachmentId: UUID) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/attachments/\(Self.path(attachmentId))"))
        request.httpMethod = "GET"
        return try await perform(request)
    }

    /// `DELETE /v1/attachments/:id`: the uploader, or the owner of the task's project.
    func deleteAttachment(_ attachmentId: UUID) async throws {
        let _: Empty = try await send("DELETE", "v1/attachments/\(Self.path(attachmentId))")
    }
}
