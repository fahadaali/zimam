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
    /// The link the API built. The app shares `InviteCode.link(for: code)`, which follows
    /// `ZimamWeb.origin`.
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

/// Invite codes and links. The link is `https://<site>/join/#<code>`: the code rides in the
/// fragment, so it never reaches a server log or a `Referer` header, and the static join page
/// (web/public/join/) reads it in the browser. Older forms are still read: the path form
/// `/join/<code>` the API returned before, `?code=`, and `zimam://join/<code>`.
/// web/public/app/lib/invites.js reads them by the same rules.
public enum InviteCode {
    /// The link shared for a new invite.
    public static func link(for code: String) -> URL {
        // The code comes from the server; as the fragment of URLComponents any character it
        // should not hold is percent-encoded, where URL(string:) would return nil.
        var components = URLComponents(url: ZimamWeb.origin, resolvingAgainstBaseURL: false)!
        components.path = "/join/"
        components.fragment = code
        return components.url!
    }

    /// Whether a URL that opened the app is an invite: a universal link to `/join` on a Zimam
    /// host, or `zimam://join/…`. Other URLs (Google's sign-in return) are left alone.
    public static func isInviteLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == ZimamWeb.appScheme { return url.host?.lowercased() == "join" }
        guard scheme == "https", let host = url.host?.lowercased(), ZimamWeb.inviteHosts.contains(host) else { return false }
        return url.path == "/join" || url.path.hasPrefix("/join/")
    }

    /// Reads an invite code from what the user pasted or opened: the code itself, any of the
    /// link forms above, or a message that ends with the code, with or without spaces around it.
    public static func extract(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "/join") {
            return fromLink(trimmed[range.upperBound...])
        }
        if isCode(trimmed) { return trimmed }
        // «…والصق هذا الرمز: <code>»: the last word of a pasted message.
        if let last = trimmed.split(whereSeparator: { $0.isWhitespace }).last, isCode(String(last)) {
            return String(last)
        }
        return nil
    }

    /// What follows `/join` in a link: `/<code>`, `/#<code>`, `#<code>` or `/?code=<code>`.
    /// Anything after the code (a query, a fragment, a slash or more text) is dropped.
    private static func fromLink(_ tail: Substring) -> String? {
        var rest = tail
        while let first = rest.first, first == "/" || first == "#" || first == "?" {
            rest.removeFirst()
        }
        if rest.hasPrefix("code=") { rest.removeFirst(5) }
        if let end = rest.firstIndex(where: { "?#/&".contains($0) || $0.isWhitespace }) {
            rest = rest[..<end]
        }
        let candidate = String(rest)
        return isCode(candidate) ? candidate : nil
    }

    /// Codes are base64url: letters, digits, "-" and "_".
    private static func isCode(_ candidate: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return candidate.count >= 8 && candidate.count <= 128 && candidate.allSatisfy(allowed.contains)
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
