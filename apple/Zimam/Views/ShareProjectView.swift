import SwiftData
import SwiftUI
import ZimamKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Sharing a project (see "المشاركة" in api/DEVELOPMENT.md): the owner invites with a
// single-use link valid for seven days, sees and revokes unused invites, changes roles and
// removes members; any other member can leave. Joining takes the link or its code.
// Everything here needs the server; offline the sheet says so and disables its actions.

/// The «مشاركة» sheet of a project.
struct ShareProjectView: View {
    let projectId: UUID
    /// Called after the user leaves the project, so the screen behind can close.
    var onLeft: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]

    @State private var members: [ProjectMember] = []
    @State private var invites: [ProjectInvite] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var working = false
    @State private var inviteRole: ProjectRole = .editor
    @State private var created: CreatedInvite?
    @State private var removing: ProjectMember?
    @State private var confirmingLeave = false

    init(projectId: UUID, onLeft: (() -> Void)? = nil) {
        self.projectId = projectId
        self.onLeft = onLeft
    }

    private var project: ProjectItem? { projects.first { $0.id == projectId } }
    private var me: UUID? { session.user?.id }

    /// From the server once loaded; before that, the creator of a project is its owner.
    private var myRole: ProjectRole? {
        if let mine = members.first(where: { $0.userId == me }) { return mine.role }
        guard let project else { return nil }
        return project.ownerId == nil || project.ownerId == me ? .owner : nil
    }

    private var isOwner: Bool { myRole == .owner }

    var body: some View {
        let online = NetworkMonitor.shared.isOnline
        NavigationStack {
            Form {
                Section {
                    Text(project?.name ?? "")
                        .font(ZimamType.title)
                        .foregroundStyle(ZimamColor.ink)
                    if !online {
                        Text("المشاركة تحتاج اتصالاً بالإنترنت. مهام المشروع تبقى متاحة على جهازك.")
                            .font(ZimamType.callout)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(ZimamType.callout)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                }

                membersSection(online: online)
                if isOwner {
                    inviteSection(online: online)
                    if !invites.isEmpty { pendingSection(online: online) }
                } else if myRole != nil && loaded {
                    leaveSection(online: online)
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
                if isOnline { Task { await load() } }
            }
        }
    }

    // MARK: Sections

    private func membersSection(online: Bool) -> some View {
        Section("الأعضاء") {
            if online && !loaded {
                AssistantStatus(phase: .loading("يُحمَّل الأعضاء…"))
            }
            ForEach(members) { member in
                MemberRow(
                    member: member,
                    name: ProjectMembers.displayName(member.name, userId: member.userId, me: me),
                    canManage: isOwner && member.role != .owner && online && !working,
                    onRole: { role in changeRole(of: member, to: role) },
                    onRemove: { removing = member }
                )
                // On the member's row, so on the iPad the dialog points at it.
                .confirmationDialog("إزالة العضو؟", isPresented: removingBinding(for: member), titleVisibility: .visible) {
                    Button("إزالة", role: .destructive) { remove(member) }
                    Button("إلغاء", role: .cancel) {}
                } message: {
                    Text("تختفي مهام المشروع من أجهزته، وتُلغى إسناداته فيه.")
                }
            }
            if loaded && members.count <= 1 && isOwner {
                Text("لم تشارك هذا المشروع بعد. أنشئ دعوة وأرسلها لمن تريد.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
    }

    private func inviteSection(online: Bool) -> some View {
        Section {
            Picker("الدور", selection: $inviteRole) {
                ForEach(ProjectRole.grantable, id: \.self) { role in
                    Text(role.arabicName).tag(role)
                }
            }
            Text(inviteRole.arabicDescription)
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            Button("إنشاء دعوة", systemImage: "link", action: createInvite)
                .buttonStyle(.zimamPrimary)
                .disabled(!online || working)
            if let created {
                CreatedInviteCard(invite: created, projectName: project?.name ?? "")
            }
        } header: {
            Text("دعوة")
        } footer: {
            Text("الدعوة تصلح لشخص واحد، وتنتهي بعد سبعة أيام.")
        }
    }

    private func pendingSection(online: Bool) -> some View {
        Section("الدعوات السارية") {
            ForEach(invites) { invite in
                HStack(spacing: ZimamSpacing.space2) {
                    VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                        Text("دعوة \(invite.role.arabicName)")
                            .font(ZimamType.body)
                        Text("تنتهي في \(formatter.dual(invite.expiresDate))")
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("إلغاء الدعوة") { revoke(invite) }
                        .buttonStyle(.zimamQuiet)
                        .disabled(!online || working)
                }
            }
        }
    }

    private func leaveSection(online: Bool) -> some View {
        Section {
            Button("مغادرة المشروع", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                confirmingLeave = true
            }
            .frame(minHeight: ZimamSpacing.space11)
            .disabled(!online || working)
            .confirmationDialog("مغادرة المشروع؟", isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button("مغادرة", role: .destructive, action: leave)
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("تختفي مهام المشروع من أجهزتك، ولا تعود إلا بدعوة جديدة.")
            }
        } footer: {
            if let role = myRole {
                Text("دورك في هذا المشروع: \(role.arabicName).")
            }
        }
    }

    private func removingBinding(for member: ProjectMember) -> Binding<Bool> {
        Binding(get: { removing?.id == member.id }, set: { if !$0, removing?.id == member.id { removing = nil } })
    }

    // MARK: Requests

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
            withAnimation(reduceMotion ? nil : .default) { created = invite }
            invites = try await session.api.invites(of: projectId)
        }
    }

    private func revoke(_ invite: ProjectInvite) {
        perform {
            try await session.api.revokeInvite(invite.id, of: projectId)
            withAnimation(reduceMotion ? nil : .default) {
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
            withAnimation(reduceMotion ? nil : .default) { members.removeAll { $0.userId == member.userId } }
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

/// A member: name and role, and for the owner a menu to change the role or remove them.
private struct MemberRow: View {
    let member: ProjectMember
    let name: String
    let canManage: Bool
    let onRole: (ProjectRole) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Text(name)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
                Text(member.role.arabicName)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            .accessibilityElement(children: .combine)
            if canManage {
                Menu {
                    Picker("الدور", selection: Binding(get: { member.role }, set: { onRole($0) })) {
                        ForEach(ProjectRole.grantable, id: \.self) { role in
                            Text(role.arabicName).tag(role)
                        }
                    }
                    Button("إزالة من المشروع", systemImage: "person.badge.minus", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .frame(minWidth: ZimamSpacing.space11, minHeight: ZimamSpacing.space11)
                }
                .accessibilityLabel("إدارة \(name)")
            }
        }
    }
}

/// The invite just created: its code, when it ends, and a share sheet with the link.
/// The code is shown only now; the server keeps a hash of it.
private struct CreatedInviteCard: View {
    let invite: CreatedInvite
    let projectName: String

    @Environment(\.dateFormatterZimam) private var formatter
    @State private var copied = false

    private var message: String {
        "انضم إلى مشروع «\(projectName)» في زمام من هذا الرابط. وإن لم يفتح، فاختر «الانضمام بدعوة» في المشاريع والصق هذا الرمز: \(invite.code)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            Text("رمز الدعوة")
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            Text(invite.code)
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("تنتهي في \(formatter.dual(invite.expiresDate))، \(formatter.time(invite.expiresDate))")
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            HStack(spacing: ZimamSpacing.space2) {
                // The web join page (ZimamWeb.origin), which also opens the app as a universal link.
                ShareLink(item: InviteCode.link(for: invite.code), subject: Text("دعوة إلى مشروع في زمام"), message: Text(message)) {
                    Label("مشاركة الدعوة", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.zimamSecondary)
                Button(action: copy) {
                    if copied {
                        Label("نُسخ الرمز", systemImage: "checkmark")
                    } else {
                        Text("نسخ الرمز")
                    }
                }
                .buttonStyle(.zimamQuiet)
            }
        }
        .padding(.vertical, ZimamSpacing.space2)
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = invite.code
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invite.code, forType: .string)
        #endif
        copied = true
    }
}

// MARK: Joining

/// «الانضمام بدعوة»: takes the link or code from the owner, shows what it offers, then joins
/// and syncs so the project and its tasks arrive.
struct JoinProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text: String
    @State private var preview: InvitePreview?
    @State private var previewCode: String?
    @State private var working = false
    @State private var problem: String?
    @FocusState private var fieldFocused: Bool

    init(code: String = "") {
        _text = State(initialValue: code)
    }

    private var code: String? { InviteCode.extract(from: text) }

    var body: some View {
        let online = NetworkMonitor.shared.isOnline
        NavigationStack {
            Form {
                Section {
                    TextField("رمز الدعوة أو رابطها", text: $text)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($fieldFocused)
                        .onSubmit(check)
                        .onChange(of: text) {
                            preview = nil
                            problem = nil
                        }
                    Button("عرض الدعوة", action: check)
                        .buttonStyle(.zimamSecondary)
                        .disabled(code == nil || working || !online)
                } footer: {
                    Text(online
                         ? "الصق الرابط أو الرمز الذي وصلك من مالك المشروع."
                         : "الانضمام يحتاج اتصالاً بالإنترنت.")
                }

                if working && preview == nil {
                    Section { AssistantStatus(phase: .loading("تُفحص الدعوة…")) }
                }

                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(ZimamType.callout)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                }

                if let preview {
                    Section("الدعوة") {
                        LabeledContent("المشروع", value: preview.projectName)
                        LabeledContent("الدور", value: preview.role.arabicName)
                        if let inviter = preview.invitedBy, !inviter.isEmpty {
                            LabeledContent("من", value: inviter)
                        }
                        LabeledContent("تنتهي في", value: formatter.dual(preview.expiresDate))
                        Text(preview.role.arabicDescription)
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                        Button("انضمام", action: join)
                            .buttonStyle(.zimamPrimary)
                            .disabled(working || !online)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("الانضمام بدعوة")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
            }
            .onAppear {
                if code != nil { check() } else { fieldFocused = true }
            }
        }
    }

    private func check() {
        guard let code, !working else { return }
        working = true
        problem = nil
        Task {
            do {
                let found = try await session.api.previewInvite(code: code)
                previewCode = code
                withAnimation(reduceMotion ? nil : .default) { preview = found }
            } catch {
                problem = SharingProblem.message(for: error)
            }
            working = false
        }
    }

    private func join() {
        guard let code = previewCode, !working else { return }
        working = true
        Task {
            do {
                _ = try await session.api.acceptInvite(code: code)
                // Brings the project, its sections, tasks and comments to this device.
                await sync.sync()
                dismiss()
            } catch {
                problem = SharingProblem.message(for: error)
            }
            working = false
        }
    }
}
