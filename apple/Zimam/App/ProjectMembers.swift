import Foundation
import Observation
import ZimamKit

/// Members of shared projects, as last loaded from the server. Kept in memory only, so the
/// assignee picker and comment authors can show names after one load per project; the
/// share sheet refreshes it. Cleared on sign-out.
@MainActor
@Observable
final class ProjectMembers {
    static let shared = ProjectMembers()

    private(set) var byProject: [UUID: [ProjectMember]] = [:]

    private init() {}

    func members(of projectId: UUID) -> [ProjectMember]? {
        byProject[projectId]
    }

    /// Loads the members from the server and keeps them.
    @discardableResult
    func load(_ projectId: UUID, api: APIClient) async throws -> [ProjectMember] {
        let members = try await api.members(of: projectId)
        byProject[projectId] = members
        return members
    }

    func set(_ members: [ProjectMember], for projectId: UUID) {
        byProject[projectId] = members
    }

    func clear() {
        byProject = [:]
    }

    /// «فهد», «أنت», or «عضو بلا اسم» when the account has no name.
    static func displayName(_ name: String?, userId: UUID?, me: UUID?) -> String {
        if let userId, userId == me { return "أنت" }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "عضو بلا اسم"
    }
}
