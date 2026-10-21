import Foundation
import Testing
@testable import ZimamKit

struct SharingTests {
    /// A URL from a literal the test knows is valid; fails the test, not the run, if it is not.
    private func makeURL(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test func decodesMembers() throws {
        let json = """
        {"members":[
          {"userId":"1f0e2d3c-4b5a-4968-8776-655443322110","name":"فهد","role":"owner","addedAt":1760000000000},
          {"userId":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","name":null,"role":"viewer","addedAt":1760000100000}
        ]}
        """
        struct Response: Decodable { let members: [ProjectMember] }
        let members = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).members
        #expect(members.count == 2)
        #expect(members[0].role == .owner)
        #expect(members[0].name == "فهد")
        #expect(members[0].id == UUID(uuidString: "1F0E2D3C-4B5A-4968-8776-655443322110"))
        #expect(members[1].name == nil)
        #expect(members[1].role == .viewer)
        #expect(!members[1].role.canEdit)
        #expect(members[1].addedAt == 1_760_000_100_000)
    }

    @Test func decodesInvites() throws {
        let list = """
        {"invites":[{"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","role":"editor",
          "createdBy":"1f0e2d3c-4b5a-4968-8776-655443322110","createdAt":1760000000000,"expiresAt":1760604800000}]}
        """
        struct Response: Decodable { let invites: [ProjectInvite] }
        let invites = try JSONDecoder().decode(Response.self, from: Data(list.utf8)).invites
        #expect(invites.first?.role == .editor)
        #expect(invites.first?.expiresAt == 1_760_604_800_000)

        let created = try JSONDecoder().decode(CreatedInvite.self, from: Data("""
        {"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","code":"abc_DEF-123456789","url":"https://zimam.work/join/abc_DEF-123456789","expiresAt":1760604800000}
        """.utf8))
        #expect(created.code == "abc_DEF-123456789")
        #expect(created.url.absoluteString == "https://zimam.work/join/abc_DEF-123456789")

        let preview = try JSONDecoder().decode(InvitePreview.self, from: Data("""
        {"projectName":"البيت","role":"viewer","invitedBy":"فهد","expiresAt":1760604800000}
        """.utf8))
        #expect(preview.projectName == "البيت")
        #expect(preview.role == .viewer)
        #expect(preview.expiresDate == Date(timeIntervalSince1970: 1_760_604_800))

        let accepted = try JSONDecoder().decode(AcceptedInvite.self, from: Data("""
        {"projectId":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","role":"editor"}
        """.utf8))
        #expect(accepted.projectId == UUID(uuidString: "2A3B4C5D-6E7F-4801-9234-56789ABCDEF0"))
    }

    @Test func decodesComments() throws {
        let json = """
        {"comments":[{"id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","taskId":"2a3b4c5d-6e7f-4801-9234-56789abcdef0",
          "authorId":"1f0e2d3c-4b5a-4968-8776-655443322110","body":"أرسلت المسودة","createdAt":1760000000000,
          "updatedAt":1760000000000,"authorName":null}]}
        """
        struct Response: Decodable { let comments: [TaskComment] }
        let comments = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).comments
        #expect(comments.first?.body == "أرسلت المسودة")
        #expect(comments.first?.authorName == nil)
        #expect(comments.first?.createdDate == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test func projectOptionsFollowTheRole() {
        let me = UUID()
        let other = UUID()
        #expect(ProjectPermissions(role: .owner) == ProjectPermissions(role: .owner))
        #expect(ProjectPermissions(role: .owner).canDelete)
        #expect(ProjectPermissions(role: .editor).canRename && ProjectPermissions(role: .editor).canArchive)
        #expect(!ProjectPermissions(role: .editor).canDelete)
        #expect(!ProjectPermissions(role: .viewer).any)
        #expect(!ProjectPermissions(role: nil).any)
        // Before the members load: the creator owns it, a project made here has no owner yet, anyone else is unknown.
        #expect(ProjectPermissions.role(ownerId: me, me: me, memberRole: nil) == .owner)
        #expect(ProjectPermissions.role(ownerId: nil, me: me, memberRole: nil) == .owner)
        #expect(ProjectPermissions.role(ownerId: other, me: me, memberRole: nil) == nil)
        #expect(ProjectPermissions.role(ownerId: other, me: me, memberRole: .editor) == .editor)
        #expect(ProjectPermissions.role(ownerId: other, me: nil, memberRole: nil) == nil)
    }

    @Test func projectOptionsWording() {
        #expect(ProjectActionText.archiveLabel(archived: false) == "أرشفة المشروع")
        #expect(ProjectActionText.archiveLabel(archived: true) == "استرجاع المشروع")
        #expect(ProjectActionText.deleteQuestion("البيت") == "حذف «البيت»؟")
        #expect(ProjectActionText.deleteNote.contains("لا يمكن استرجاعه"))
    }

    @Test func roleNames() {
        #expect(ProjectRole.owner.arabicName == "المالك")
        #expect(ProjectRole.editor.arabicName == "محرر")
        #expect(ProjectRole.viewer.arabicName == "مشاهد")
        #expect(ProjectRole.grantable == [.editor, .viewer])
    }

    @Test func extractsInviteCodes() {
        let code = "Zx9_Kq-3vB7mN2pL5tR8wY1aC4dF6gH0jS3uE5iO7k"
        #expect(InviteCode.extract(from: code) == code)
        #expect(InviteCode.extract(from: "  \(code)\n") == code)
        #expect(InviteCode.extract(from: "https://zimam.work/join/\(code)") == code)
        #expect(InviteCode.extract(from: "انضم إلى مشروعي: https://zimam.work/join/\(code)") == code)
        #expect(InviteCode.extract(from: "https://zimam.work/join/\(code)/?ref=share") == code)
        #expect(InviteCode.extract(from: "") == nil)
        #expect(InviteCode.extract(from: "رمز خاطئ") == nil)
        #expect(InviteCode.extract(from: "abc") == nil)
        #expect(InviteCode.extract(from: "abc/def../../me") == nil)
    }

    @Test func extractsInviteCodesFromEveryLinkForm() {
        let code = "Zx9_Kq-3vB7mN2pL5tR8wY1aC4dF6gH0jS3uE5iO7k"
        let site = "https://zimam.work"
        // The current link: the code in the fragment.
        #expect(InviteCode.extract(from: "\(site)/join/#\(code)") == code)
        #expect(InviteCode.extract(from: "\(site)/join#\(code)") == code)
        #expect(InviteCode.extract(from: "انضم إلى مشروعي: \(site)/join/#\(code) شكراً") == code)
        // A query, the old path form, and the app's scheme.
        #expect(InviteCode.extract(from: "\(site)/join/?code=\(code)") == code)
        #expect(InviteCode.extract(from: "\(site)/join/?code=\(code)&ref=share") == code)
        #expect(InviteCode.extract(from: "\(site)/join/#code=\(code)") == code)
        #expect(InviteCode.extract(from: "\(site)/join/\(code)") == code)
        #expect(InviteCode.extract(from: "zimam://join/\(code)") == code)
        // The share message pasted whole, ending with the code.
        #expect(InviteCode.extract(from: "وإن لم يفتح، فاختر «الانضمام بدعوة» في المشاريع والصق هذا الرمز: \(code)") == code)
        // A link without a code, or with something that is not one.
        #expect(InviteCode.extract(from: "\(site)/join/") == nil)
        #expect(InviteCode.extract(from: "\(site)/join/#") == nil)
        #expect(InviteCode.extract(from: "\(site)/join/#<script>") == nil)
        #expect(InviteCode.extract(from: "\(site)/join/?code=short") == nil)
    }

    @Test func buildsAndRecognisesInviteLinks() throws {
        let code = "Zx9_Kq-3vB7mN2pL5tR8wY1aC4dF6gH0jS3uE5iO7k"
        let link = InviteCode.link(for: code)
        #expect(link.absoluteString == "https://zimam.work/join/#\(code)")
        #expect(link.fragment == code)
        #expect(InviteCode.isInviteLink(link))
        #expect(InviteCode.extract(from: link.absoluteString) == code)

        #expect(InviteCode.isInviteLink(try makeURL("https://www.zimam.work/join/\(code)")))
        #expect(InviteCode.isInviteLink(try makeURL("zimam://join/\(code)")))
        // Not invites: another path or host, and Google's sign-in return.
        #expect(!InviteCode.isInviteLink(try makeURL("https://zimam.work/app/")))
        #expect(!InviteCode.isInviteLink(try makeURL("https://example.com/join/\(code)")))
        #expect(!InviteCode.isInviteLink(try makeURL("http://zimam.work/join/\(code)")))
        #expect(!InviteCode.isInviteLink(try makeURL("com.googleusercontent.apps.1-abc:/oauth2redirect?code=x")))

        #expect(ZimamWeb.privacyPolicy.absoluteString == "https://zimam.work/privacy/")
        #expect(ZimamWeb.terms.absoluteString == "https://zimam.work/terms/")
    }

    @Test func sharingMessages() {
        #expect(SharingProblem.message(for: APIError(status: 410, code: "invite_expired", message: "")) == "انتهت صلاحية هذه الدعوة. اطلب دعوة جديدة.")
        #expect(SharingProblem.message(for: APIError(status: 400, code: "owner_cannot_leave", message: "")) == "المالك لا يغادر مشروعه، ويستطيع حذفه.")
        #expect(SharingProblem.message(for: URLError(.notConnectedToInternet)) == "لا يوجد اتصال بالإنترنت. المشاركة تحتاج الاتصال.")
    }
}
