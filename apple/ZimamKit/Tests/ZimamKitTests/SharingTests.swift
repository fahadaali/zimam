import XCTest
@testable import ZimamKit

final class SharingTests: XCTestCase {
    func testDecodesMembers() throws {
        let json = """
        {"members":[
          {"userId":"1f0e2d3c-4b5a-4968-8776-655443322110","name":"فهد","role":"owner","addedAt":1760000000000},
          {"userId":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","name":null,"role":"viewer","addedAt":1760000100000}
        ]}
        """
        struct Response: Decodable { let members: [ProjectMember] }
        let members = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).members
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0].role, .owner)
        XCTAssertEqual(members[0].name, "فهد")
        XCTAssertEqual(members[0].id, UUID(uuidString: "1F0E2D3C-4B5A-4968-8776-655443322110"))
        XCTAssertNil(members[1].name)
        XCTAssertEqual(members[1].role, .viewer)
        XCTAssertFalse(members[1].role.canEdit)
        XCTAssertEqual(members[1].addedAt, 1_760_000_100_000)
    }

    func testDecodesInvites() throws {
        let list = """
        {"invites":[{"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","role":"editor",
          "createdBy":"1f0e2d3c-4b5a-4968-8776-655443322110","createdAt":1760000000000,"expiresAt":1760604800000}]}
        """
        struct Response: Decodable { let invites: [ProjectInvite] }
        let invites = try JSONDecoder().decode(Response.self, from: Data(list.utf8)).invites
        XCTAssertEqual(invites.first?.role, .editor)
        XCTAssertEqual(invites.first?.expiresAt, 1_760_604_800_000)

        let created = try JSONDecoder().decode(CreatedInvite.self, from: Data("""
        {"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","code":"abc_DEF-123456789","url":"https://zimam.app/join/abc_DEF-123456789","expiresAt":1760604800000}
        """.utf8))
        XCTAssertEqual(created.code, "abc_DEF-123456789")
        XCTAssertEqual(created.url.absoluteString, "https://zimam.app/join/abc_DEF-123456789")

        let preview = try JSONDecoder().decode(InvitePreview.self, from: Data("""
        {"projectName":"البيت","role":"viewer","invitedBy":"فهد","expiresAt":1760604800000}
        """.utf8))
        XCTAssertEqual(preview.projectName, "البيت")
        XCTAssertEqual(preview.role, .viewer)
        XCTAssertEqual(preview.expiresDate, Date(timeIntervalSince1970: 1_760_604_800))

        let accepted = try JSONDecoder().decode(AcceptedInvite.self, from: Data("""
        {"projectId":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","role":"editor"}
        """.utf8))
        XCTAssertEqual(accepted.projectId, UUID(uuidString: "2A3B4C5D-6E7F-4801-9234-56789ABCDEF0"))
    }

    func testDecodesComments() throws {
        let json = """
        {"comments":[{"id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","taskId":"2a3b4c5d-6e7f-4801-9234-56789abcdef0",
          "authorId":"1f0e2d3c-4b5a-4968-8776-655443322110","body":"أرسلت المسودة","createdAt":1760000000000,
          "updatedAt":1760000000000,"authorName":null}]}
        """
        struct Response: Decodable { let comments: [TaskComment] }
        let comments = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).comments
        XCTAssertEqual(comments.first?.body, "أرسلت المسودة")
        XCTAssertNil(comments.first?.authorName)
        XCTAssertEqual(comments.first?.createdDate, Date(timeIntervalSince1970: 1_760_000_000))
    }

    func testRoleNames() {
        XCTAssertEqual(ProjectRole.owner.arabicName, "المالك")
        XCTAssertEqual(ProjectRole.editor.arabicName, "محرر")
        XCTAssertEqual(ProjectRole.viewer.arabicName, "مشاهد")
        XCTAssertEqual(ProjectRole.grantable, [.editor, .viewer])
    }

    func testExtractsInviteCodes() {
        let code = "Zx9_Kq-3vB7mN2pL5tR8wY1aC4dF6gH0jS3uE5iO7k"
        XCTAssertEqual(InviteCode.extract(from: code), code)
        XCTAssertEqual(InviteCode.extract(from: "  \(code)\n"), code)
        XCTAssertEqual(InviteCode.extract(from: "https://zimam.app/join/\(code)"), code)
        XCTAssertEqual(InviteCode.extract(from: "انضم إلى مشروعي: https://zimam.app/join/\(code)"), code)
        XCTAssertEqual(InviteCode.extract(from: "https://zimam.app/join/\(code)/?ref=share"), code)
        XCTAssertNil(InviteCode.extract(from: ""))
        XCTAssertNil(InviteCode.extract(from: "رمز خاطئ"))
        XCTAssertNil(InviteCode.extract(from: "abc"))
        XCTAssertNil(InviteCode.extract(from: "abc/def../../me"))
    }

    func testExtractsInviteCodesFromEveryLinkForm() {
        let code = "Zx9_Kq-3vB7mN2pL5tR8wY1aC4dF6gH0jS3uE5iO7k"
        let site = "https://zimam-web.fahad2ao.workers.dev"
        // The current link: the code in the fragment.
        XCTAssertEqual(InviteCode.extract(from: "\(site)/join/#\(code)"), code)
        XCTAssertEqual(InviteCode.extract(from: "\(site)/join#\(code)"), code)
        XCTAssertEqual(InviteCode.extract(from: "انضم إلى مشروعي: \(site)/join/#\(code) شكراً"), code)
        // A query, the old path form on either host, and the app's scheme.
        XCTAssertEqual(InviteCode.extract(from: "\(site)/join/?code=\(code)"), code)
        XCTAssertEqual(InviteCode.extract(from: "\(site)/join/?code=\(code)&ref=share"), code)
        XCTAssertEqual(InviteCode.extract(from: "\(site)/join/#code=\(code)"), code)
        XCTAssertEqual(InviteCode.extract(from: "\(site)/join/\(code)"), code)
        XCTAssertEqual(InviteCode.extract(from: "zimam://join/\(code)"), code)
        // The share message pasted whole, ending with the code.
        XCTAssertEqual(InviteCode.extract(from: "وإن لم يفتح، فاختر «الانضمام بدعوة» في المشاريع والصق هذا الرمز: \(code)"), code)
        // A link without a code, or with something that is not one.
        XCTAssertNil(InviteCode.extract(from: "\(site)/join/"))
        XCTAssertNil(InviteCode.extract(from: "\(site)/join/#"))
        XCTAssertNil(InviteCode.extract(from: "\(site)/join/#<script>"))
        XCTAssertNil(InviteCode.extract(from: "\(site)/join/?code=short"))
    }

    func testBuildsAndRecognisesInviteLinks() throws {
        let code = "Zx9_Kq-3vB7mN2pL5tR8wY1aC4dF6gH0jS3uE5iO7k"
        let link = InviteCode.link(for: code)
        XCTAssertEqual(link.absoluteString, "https://zimam-web.fahad2ao.workers.dev/join/#\(code)")
        XCTAssertEqual(link.fragment, code)
        XCTAssertTrue(InviteCode.isInviteLink(link))
        XCTAssertEqual(InviteCode.extract(from: link.absoluteString), code)

        XCTAssertTrue(InviteCode.isInviteLink(try XCTUnwrap(URL(string: "https://zimam.app/join/\(code)"))))
        XCTAssertTrue(InviteCode.isInviteLink(try XCTUnwrap(URL(string: "zimam://join/\(code)"))))
        // Not invites: another path or host, and Google's sign-in return.
        XCTAssertFalse(InviteCode.isInviteLink(try XCTUnwrap(URL(string: "https://zimam-web.fahad2ao.workers.dev/app/"))))
        XCTAssertFalse(InviteCode.isInviteLink(try XCTUnwrap(URL(string: "https://example.com/join/\(code)"))))
        XCTAssertFalse(InviteCode.isInviteLink(try XCTUnwrap(URL(string: "http://zimam.app/join/\(code)"))))
        XCTAssertFalse(InviteCode.isInviteLink(try XCTUnwrap(URL(string: "com.googleusercontent.apps.1-abc:/oauth2redirect?code=x"))))

        XCTAssertEqual(ZimamWeb.privacyPolicy.absoluteString, "https://zimam-web.fahad2ao.workers.dev/privacy/")
        XCTAssertEqual(ZimamWeb.terms.absoluteString, "https://zimam-web.fahad2ao.workers.dev/terms/")
    }

    func testSharingMessages() {
        XCTAssertEqual(SharingProblem.message(for: APIError(status: 410, code: "invite_expired", message: "")),
                       "انتهت صلاحية هذه الدعوة. اطلب دعوة جديدة.")
        XCTAssertEqual(SharingProblem.message(for: APIError(status: 400, code: "owner_cannot_leave", message: "")),
                       "المالك لا يغادر مشروعه، ويستطيع حذفه.")
        XCTAssertEqual(SharingProblem.message(for: URLError(.notConnectedToInternet)),
                       "لا يوجد اتصال بالإنترنت. المشاركة تحتاج الاتصال.")
    }
}
