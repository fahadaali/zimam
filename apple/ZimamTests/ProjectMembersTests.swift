import Foundation
import Testing
import ZimamKit
@testable import Zimam

/// `ProjectMembers` (Zimam/App/ProjectMembers.swift) against `StubURLProtocol`, never the network.
/// It is a singleton, so each test uses its own project. Serialized because the stub answers on
/// URLSession's loading thread, which a held request occupies.
@MainActor
@Suite(.serialized)
struct ProjectMembersTests {
    private func makeAPI() -> APIClient {
        APIClient(baseURL: URL(string: "https://zimam.test")!, session: StubURLProtocol.session(), token: { "token" })
    }

    private func path(_ projectId: UUID) -> String {
        "/v1/projects/\(projectId.uuidString.lowercased())/members"
    }

    @Test func loadKeepsTheServerList() async throws {
        let members = ProjectMembers.shared
        let api = makeAPI()
        let projectId = UUID()
        StubURLProtocol.release(path(projectId))

        let loaded = try await members.load(projectId, api: api)

        #expect(loaded == [StubURLProtocol.serverMember])
        #expect(members.members(of: projectId) == [StubURLProtocol.serverMember])
    }

    /// A role change or a removal (`set`) made while a load is in flight wins over the load's
    /// older answer.
    @Test func aChangeDuringALoadIsNotOverwritten() async throws {
        let members = ProjectMembers.shared
        let api = makeAPI()
        let projectId = UUID()
        let load = Task { try await members.load(projectId, api: api) }
        try await StubURLProtocol.waitForRequest(to: path(projectId))

        let changed = [ProjectMember(userId: UUID(), name: "سارة", role: .editor, addedAt: 1_760_000_100_000)]
        members.set(changed, for: projectId)
        StubURLProtocol.release(path(projectId))

        let loaded = try await load.value
        #expect(members.members(of: projectId) == changed)
        #expect(loaded == changed)
    }

    /// A second load while one is in flight waits for it instead of asking the server again.
    @Test func concurrentLoadsShareOneRequest() async throws {
        let members = ProjectMembers.shared
        let api = makeAPI()
        let projectId = UUID()
        let first = Task { try await members.load(projectId, api: api) }
        let second = Task { try await members.load(projectId, api: api) }
        try await StubURLProtocol.waitForRequest(to: path(projectId))
        // Give the second load its turn on the main actor before the answer comes.
        try await Task.sleep(for: .milliseconds(100))
        StubURLProtocol.release(path(projectId))

        let a = try await first.value
        let b = try await second.value
        #expect(a == [StubURLProtocol.serverMember])
        #expect(b == a)
        #expect(StubURLProtocol.requestCount(for: path(projectId)) == 1)
    }
}
