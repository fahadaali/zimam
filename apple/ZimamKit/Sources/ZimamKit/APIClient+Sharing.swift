import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Project sharing and task comments. Both need the server; neither is kept offline.
// Errors come as `APIError` (see `SharingProblem`).

public extension APIClient {
    // MARK: Members

    func members(of projectId: UUID) async throws -> [ProjectMember] {
        struct Response: Decodable { let members: [ProjectMember] }
        let response: Response = try await send("GET", "v1/projects/\(Self.path(projectId))/members")
        return response.members
    }

    /// The owner switches a member between editor and viewer.
    func changeRole(of userId: UUID, in projectId: UUID, to role: ProjectRole) async throws -> ProjectMember {
        struct Body: Encodable { let role: ProjectRole }
        return try await send("PATCH", "v1/projects/\(Self.path(projectId))/members/\(Self.path(userId))", body: Body(role: role))
    }

    /// The owner removes a member, or a member passes their own id to leave.
    func removeMember(_ userId: UUID, from projectId: UUID) async throws {
        let _: Empty = try await send("DELETE", "v1/projects/\(Self.path(projectId))/members/\(Self.path(userId))")
    }

    // MARK: Invites

    /// The owner's unused invites, without their codes.
    func invites(of projectId: UUID) async throws -> [ProjectInvite] {
        struct Response: Decodable { let invites: [ProjectInvite] }
        let response: Response = try await send("GET", "v1/projects/\(Self.path(projectId))/invites")
        return response.invites
    }

    func createInvite(to projectId: UUID, role: ProjectRole) async throws -> CreatedInvite {
        struct Body: Encodable { let role: ProjectRole }
        return try await send("POST", "v1/projects/\(Self.path(projectId))/invites", body: Body(role: role))
    }

    /// Revokes an invite before it is used; revoking twice is fine.
    func revokeInvite(_ inviteId: UUID, of projectId: UUID) async throws {
        let _: Empty = try await send("DELETE", "v1/projects/\(Self.path(projectId))/invites/\(Self.path(inviteId))")
    }

    func previewInvite(code: String) async throws -> InvitePreview {
        try await send("GET", "v1/invites/\(code)")
    }

    func acceptInvite(code: String) async throws -> AcceptedInvite {
        try await send("POST", "v1/invites/\(code)/accept")
    }

    // MARK: Comments

    func comments(on taskId: UUID) async throws -> [TaskComment] {
        struct Response: Decodable { let comments: [TaskComment] }
        let response: Response = try await send("GET", "v1/tasks/\(Self.path(taskId))/comments")
        return response.comments
    }

    func addComment(_ body: String, to taskId: UUID) async throws -> TaskComment {
        struct Body: Encodable { let body: String }
        return try await send("POST", "v1/tasks/\(Self.path(taskId))/comments", body: Body(body: body))
    }

    /// Deletes a comment; the author only.
    func deleteComment(_ commentId: UUID) async throws {
        let _: Empty = try await send("DELETE", "v1/comments/\(Self.path(commentId))")
    }
}
