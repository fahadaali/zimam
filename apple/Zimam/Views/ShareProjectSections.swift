import SwiftUI
import ZimamKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The sections of the «مشاركة» sheet (`ShareProjectView`). The sheet owns the state and the
// requests; these take what they show and call back for each action.

/// The project's name, and why sharing is unavailable when it is.
struct ShareProjectHeaderSection: View {
    let projectName: String
    let online: Bool
    let problem: String?

    var body: some View {
        Section {
            Text(projectName)
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
    }
}

/// «الأعضاء»: each member with their role; the owner can change roles and remove members.
struct ShareMembersSection: View {
    let members: [ProjectMember]
    let me: UUID?
    let isOwner: Bool
    let online: Bool
    let loaded: Bool
    let working: Bool
    /// The member whose removal is being confirmed.
    @Binding var removing: ProjectMember?
    let onChangeRole: (ProjectMember, ProjectRole) -> Void
    let onRemove: (ProjectMember) -> Void

    var body: some View {
        Section("الأعضاء") {
            if online && !loaded {
                AssistantStatus(phase: .loading("يُحمَّل الأعضاء…"))
            }
            ForEach(members) { member in
                ShareMemberRow(
                    member: member,
                    name: ProjectMembers.displayName(member.name, userId: member.userId, me: me),
                    canManage: isOwner && member.role != .owner && online && !working,
                    onRole: { role in onChangeRole(member, role) },
                    onRemove: { removing = member }
                )
                // On the member's row, so on the iPad the dialog points at it.
                .confirmationDialog("إزالة العضو؟", isPresented: removingBinding(for: member), titleVisibility: .visible) {
                    Button("إزالة", role: .destructive) { onRemove(member) }
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

    private func removingBinding(for member: ProjectMember) -> Binding<Bool> {
        Binding(get: { removing?.id == member.id }, set: { if !$0, removing?.id == member.id { removing = nil } })
    }
}

/// «دعوة»: the role to invite with, and the invite just created.
struct ShareInviteSection: View {
    @Binding var inviteRole: ProjectRole
    let created: CreatedInvite?
    let projectName: String
    let online: Bool
    let working: Bool
    let onCreate: () -> Void

    var body: some View {
        Section {
            Picker("الدور", selection: $inviteRole) {
                ForEach(ProjectRole.grantable, id: \.self) { role in
                    Text(role.arabicName).tag(role)
                }
            }
            Text(inviteRole.arabicDescription)
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            Button("إنشاء دعوة", systemImage: "link", action: onCreate)
                .buttonStyle(.zimamPrimary)
                .disabled(!online || working)
            if let created {
                CreatedInviteCard(invite: created, projectName: projectName)
            }
        } header: {
            Text("دعوة")
        } footer: {
            Text("الدعوة تصلح لشخص واحد، وتنتهي بعد سبعة أيام.")
        }
    }
}

/// «الدعوات السارية»: unused invites, each with «إلغاء الدعوة».
struct SharePendingInvitesSection: View {
    let invites: [ProjectInvite]
    let online: Bool
    let working: Bool
    let onRevoke: (ProjectInvite) -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
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
                    Button("إلغاء الدعوة") { onRevoke(invite) }
                        .buttonStyle(.zimamQuiet)
                        .disabled(!online || working)
                }
            }
        }
    }
}

/// «مغادرة المشروع» for a member who is not the owner, confirmed first.
struct ShareLeaveSection: View {
    let myRole: ProjectRole?
    let online: Bool
    let working: Bool
    let onLeave: () -> Void

    @State private var confirmingLeave = false

    init(myRole: ProjectRole?, online: Bool, working: Bool, onLeave: @escaping () -> Void) {
        self.myRole = myRole
        self.online = online
        self.working = working
        self.onLeave = onLeave
    }

    var body: some View {
        Section {
            Button("مغادرة المشروع", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                confirmingLeave = true
            }
            .frame(minHeight: ZimamSpacing.space11)
            .disabled(!online || working)
            .confirmationDialog("مغادرة المشروع؟", isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button("مغادرة", role: .destructive, action: onLeave)
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
}

/// A member: name and role, and for the owner a menu to change the role or remove them.
struct ShareMemberRow: View {
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
struct CreatedInviteCard: View {
    let invite: CreatedInvite
    let projectName: String

    @Environment(\.dateFormatterZimam) private var formatter
    @State private var copied = false

    private var message: String {
        "انضم إلى مشروع «\(projectName)» في زمام من هذا الرابط. وإن لم يفتح، فاختر «الانضمام بدعوة» في المشاريع والصق هذا الرمز: \(invite.code)"
    }

    init(invite: CreatedInvite, projectName: String) {
        self.invite = invite
        self.projectName = projectName
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
