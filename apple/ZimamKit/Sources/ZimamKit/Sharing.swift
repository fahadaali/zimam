import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Shared projects: members, invites and task comments (see "المشاركة" in api/DEVELOPMENT.md).

/// A member's role. The owner and editors edit; viewers read and comment; only the
/// owner invites, changes roles and removes members.
public enum ProjectRole: String, Codable, Sendable, CaseIterable {
    case owner, editor, viewer

    /// The roles an invite or a role change can grant.
    public static let grantable: [ProjectRole] = [.editor, .viewer]

    public var arabicName: String {
        switch self {
        case .owner: "المالك"
        case .editor: "محرر"
        case .viewer: "مشاهد"
        }
    }

    /// What the role allows, in one short line.
    public var arabicDescription: String {
        switch self {
        case .owner: "يدير المشروع وأعضاءه"
        case .editor: "يضيف المهام ويعدّلها"
        case .viewer: "يقرأ ويعلّق فقط"
        }
    }

    public var canEdit: Bool { self != .viewer }
}

/// `GET /v1/projects/:id/members`: the owner first, then by join date.
public struct ProjectMember: Codable, Equatable, Sendable, Identifiable {
    public var userId: UUID
    public var name: String?
    public var role: ProjectRole
    public var addedAt: Milliseconds

    public var id: UUID { userId }

    public init(userId: UUID, name: String?, role: ProjectRole, addedAt: Milliseconds) {
        self.userId = userId
        self.name = name
        self.role = role
        self.addedAt = addedAt
    }
}

/// An unused invite, as the owner sees it. Its code is never shown again after creation.
public struct ProjectInvite: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var role: ProjectRole
    public var createdBy: UUID?
    public var createdAt: Milliseconds
    public var expiresAt: Milliseconds

    public var expiresDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000) }
}

/// `POST /v1/projects/:id/invites`: a single-use link valid for seven days.
public struct CreatedInvite: Codable, Equatable, Sendable {
    public var id: UUID
    public var code: String
    /// `https://zimam.app/join/<code>`.
    public var url: URL
    public var expiresAt: Milliseconds

    public var expiresDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000) }
}

/// `GET /v1/invites/:code`: what an invite offers, shown before joining.
public struct InvitePreview: Codable, Equatable, Sendable {
    public var projectName: String
    public var role: ProjectRole
    public var invitedBy: String?
    public var expiresAt: Milliseconds

    public var expiresDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000) }
}

/// `POST /v1/invites/:code/accept`. A member keeps the higher of their role and the invite's.
public struct AcceptedInvite: Codable, Equatable, Sendable {
    public var projectId: UUID
    public var role: ProjectRole
}

/// A task comment with its author's name, oldest first.
public struct TaskComment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var taskId: UUID
    public var authorId: UUID?
    public var authorName: String?
    public var body: String
    public var createdAt: Milliseconds
    public var updatedAt: Milliseconds

    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000) }
}

/// Reads an invite code from what the user pasted: the code itself, or the
/// `https://zimam.app/join/<code>` link, with or without spaces around it.
public enum InviteCode {
    public static func extract(from text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = candidate.range(of: "/join/") {
            candidate = String(candidate[range.upperBound...])
        }
        // Drop any query or fragment, and a trailing slash.
        if let end = candidate.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == "/" }) {
            candidate = String(candidate[..<end])
        }
        // Codes are base64url: letters, digits, "-" and "_".
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard candidate.count >= 8, candidate.count <= 128, candidate.allSatisfy(allowed.contains) else { return nil }
        return candidate
    }
}

/// The Arabic sentence for a failed sharing or comment request.
public enum SharingProblem {
    public static func message(for error: Error) -> String {
        if NetworkFailure.isOffline(error) { return "لا يوجد اتصال بالإنترنت. المشاركة تحتاج الاتصال." }
        guard let api = error as? APIError else { return "تعذّر الاتصال بزمام. حاول مرة أخرى." }
        switch api.code {
        case "forbidden": return "هذا الإجراء للمالك وحده."
        case "not_found": return "لم يُعثر عليه. ربما لم يُزامَن بعد أو حُذف."
        case "invite_expired": return "انتهت صلاحية هذه الدعوة. اطلب دعوة جديدة."
        case "invite_used": return "استُعملت هذه الدعوة من قبل. اطلب دعوة جديدة."
        case "invite_revoked": return "ألغى المالك هذه الدعوة."
        case "gone": return "حُذف هذا المشروع."
        case "owner_cannot_leave": return "المالك لا يغادر مشروعه، ويستطيع حذفه."
        case "cannot_change_owner": return "لا يتغيّر دور المالك."
        case "invalid": return "تعذّر الطلب. تحقّق مما أدخلته."
        default: break
        }
        if api.isUnauthorized { return "انتهت الجلسة. سجّل الدخول مرة أخرى." }
        return "تعذّر الاتصال بزمام. حاول مرة أخرى."
    }
}
