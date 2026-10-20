import SwiftData
import SwiftUI
import ZimamKit

// Sharing a project (see "المشاركة" in api/DEVELOPMENT.md): the owner invites with a
// single-use link valid for seven days, sees and revokes unused invites, changes roles and
// removes members; any other member can leave. Joining takes the link or its code
// (JoinProjectView.swift). Everything here needs the server; offline the sheet says so and
// disables its actions. The sections are in ShareProjectSections.swift.

/// The «مشاركة» sheet of a project.
struct ShareProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]

    let projectId: UUID
    /// Called after the user leaves the project, so the screen behind can close.
    var onLeft: (() -> Void)?

    @State private var members: [ProjectMember] = []
    @State private var invites: [ProjectInvite] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var working = false
    @State private var inviteRole: ProjectRole = .editor
    @State private var created: CreatedInvite?
    @State private var removing: ProjectMember?

    private var project: ProjectItem? { projects.first { $0.id == projectId } }
    private var me: UUID? { session.user?.id }

    /// From the server once loaded; before that, the creator of a project is its owner.
    private var myRole: ProjectRole? {
        if let mine = members.first(where: { $0.userId == me }) { return mine.role }
        guard let project else { return nil }
        return project.ownerId == nil || project.ownerId == me ? .owner : nil
    }

    private var isOwner: Bool { myRole == .owner }

    init(projectId: UUID, onLeft: (() -> Void)? = nil) {
        self.projectId = projectId
        self.onLeft = onLeft
    }

    var body: some View {
        let online = NetworkMonitor.shared.isOnline
        NavigationStack {
            Form {
                ShareProjectHeaderSection(projectName: project?.name ?? "", online: online, problem: problem)

                ShareMembersSection(
                    members: members,
                    me: me,
                    isOwner: isOwner,
                    online: online,
                    loaded: loaded,
                    working: working,
                    removing: $removing,
                    onChangeRole: { member, role in changeRole(of: member, to: role) },
                    onRemove: { member in remove(member) }
                )
                if isOwner {
                    ShareInviteSection(
                        inviteRole: $inviteRole,
                        created: created,
                        projectName: project?.name ?? "",
                        online: online,
                        working: working,
                        onCreate: { createInvite() }
                    )
                    if !invites.isEmpty {
                        SharePendingInvitesSection(invites: invites, online: online, working: working, onRevoke: { invite in revoke(invite) })
                    }
                } else if myRole != nil && loaded {
                    ShareLeaveSection(myRole: myRole, online: online, working: working, onLeave: { leave() })
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("مشاركة المشروع")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: online) { _, isOnline in
                connectionChanged(isOnline)
            }
        }
    }

    // MARK: Requests

    private func connectionChanged(_ isOnline: Bool) {
        if isOnline { Task { await load() } }
    }

    private func load() async {
        guard NetworkMonitor.shared.isOnline else { return }
        // A project made on this device reaches the server with the next sync.
        if project?.isDirty == true { await sync.sync() }
        do {
            members = try await ProjectMembers.shared.load(projectId, api: session.api)
            if isOwner {
                invites = try await session.api.invites(of: projectId)
            } else {
                invites = []
            }
            problem = nil
        } catch {
            problem = SharingProblem.message(for: error)
        }
        loaded = true
    }

    private func perform(_ request: @escaping @MainActor () async throws -> Void) {
        working = true
        Task {
            do {
                try await request()
                problem = nil
            } catch {
                problem = SharingProblem.message(for: error)
            }
            working = false
        }
    }

    private func createInvite() {
        let role = inviteRole
        perform {
            let invite = try await session.api.createInvite(to: projectId, role: role)
            withAnimation(.zimam(reduceMotion: reduceMotion)) { created = invite }
            invites = try await session.api.invites(of: projectId)
        }
    }

    private func revoke(_ invite: ProjectInvite) {
        perform {
            try await session.api.revokeInvite(invite.id, of: projectId)
            withAnimation(.zimam(reduceMotion: reduceMotion)) {
                invites.removeAll { $0.id == invite.id }
                if created?.id == invite.id { created = nil }
            }
        }
    }

    private func changeRole(of member: ProjectMember, to role: ProjectRole) {
        guard role != member.role else { return }
        perform {
            let updated = try await session.api.changeRole(of: member.userId, in: projectId, to: role)
            if let index = members.firstIndex(where: { $0.userId == updated.userId }) {
                members[index] = updated
            }
            ProjectMembers.shared.set(members, for: projectId)
        }
    }

    private func remove(_ member: ProjectMember) {
        removing = nil
        perform {
            try await session.api.removeMember(member.userId, from: projectId)
            withAnimation(.zimam(reduceMotion: reduceMotion)) { members.removeAll { $0.userId == member.userId } }
            ProjectMembers.shared.set(members, for: projectId)
        }
    }

    private func leave() {
        guard let me else { return }
        perform {
            try await session.api.removeMember(me, from: projectId)
            // The pull removes the project and its tasks from this device.
            await sync.sync()
            dismiss()
            onLeft?()
        }
    }
}
