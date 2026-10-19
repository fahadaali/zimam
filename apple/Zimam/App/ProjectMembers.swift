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
    /// The load in flight per project: a second caller waits for it instead of asking again.
    @ObservationIgnored private var loading: [UUID: Task<[ProjectMember], any Error>] = [:]
    /// Bumped by `set`. A load that started before a change (a role, a removal) and answers
    /// after it does not put the older list back.
    @ObservationIgnored private var versions: [UUID: Int] = [:]

    private init() {}

    func members(of projectId: UUID) -> [ProjectMember]? {
        byProject[projectId]
    }

    /// Loads the members from the server and keeps them.
    @discardableResult
    func load(_ projectId: UUID, api: APIClient) async throws -> [ProjectMember] {
        if let running = loading[projectId] { return try await running.value }
        let version = versions[projectId, default: 0]
        let request = Task { try await api.members(of: projectId) }
        loading[projectId] = request
        defer { if loading[projectId] == request { loading[projectId] = nil } }
        let members = try await request.value
        guard versions[projectId, default: 0] == version else { return byProject[projectId] ?? members }
        byProject[projectId] = members
        return members
    }

    func set(_ members: [ProjectMember], for projectId: UUID) {
        versions[projectId, default: 0] += 1
        byProject[projectId] = members
    }

    func clear() {
        for request in loading.values { request.cancel() }
        loading = [:]
        versions = [:]
        byProject = [:]
    }

    /// «فهد», «أنت», or «عضو بلا اسم» when the account has no name.
    static func displayName(_ name: String?, userId: UUID?, me: UUID?) -> String {
        if let userId, userId == me { return "أنت" }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "عضو بلا اسم"
    }
}
