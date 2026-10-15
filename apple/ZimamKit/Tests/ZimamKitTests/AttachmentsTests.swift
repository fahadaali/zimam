import XCTest
@testable import ZimamKit

final class AttachmentsTests: XCTestCase {
    let ar = Locale(identifier: "ar-SA")

    func testDecodesTheList() throws {
        let json = """
        {"attachments":[{"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","taskId":"1f0e2d3c-4b5a-4968-8776-655443322110",
          "projectId":null,"uploaderId":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","uploaderName":"سارة",
          "fileName":"عقد الإيجار.pdf","contentType":"application/pdf","size":2048,
          "createdAt":1760000000000,"updatedAt":1760000000000,"canDelete":true}],
         "maxFileBytes":26214400,"canAdd":false}
        """
        let list = try JSONDecoder().decode(TaskAttachments.self, from: Data(json.utf8))
        XCTAssertFalse(list.canAdd)
        XCTAssertEqual(list.maxFileBytes, AttachmentRules.maxFileBytes)
        let attachment = try XCTUnwrap(list.attachments.first)
        XCTAssertEqual(attachment.id, UUID(uuidString: "2A3B4C5D-6E7F-4801-9234-56789ABCDEF0"))
        XCTAssertNil(attachment.projectId)
        XCTAssertEqual(attachment.fileName, "عقد الإيجار.pdf")
        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertEqual(attachment.canDelete, true)

        // Kept in the Caches folder as JSON, and read back the same.
        let again = try JSONDecoder().decode(TaskAttachments.self, from: JSONEncoder().encode(list))
        XCTAssertEqual(again, list)

        // An upload's answer, and a sync row, may come without canDelete or a name.
        let bare = try JSONDecoder().decode(TaskAttachment.self, from: Data("""
        {"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","taskId":"1f0e2d3c-4b5a-4968-8776-655443322110",
         "projectId":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","uploaderId":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f",
         "fileName":"صورة.heic","contentType":"image/heic","size":10,"createdAt":1,"updatedAt":1}
        """.utf8))
        XCTAssertNil(bare.canDelete)
        XCTAssertNil(bare.uploaderName)
        XCTAssertEqual(bare.kind, .image)
    }

    func testKinds() {
        XCTAssertEqual(AttachmentKind(contentType: "image/jpeg", fileName: "a.jpg"), .image)
        XCTAssertEqual(AttachmentKind(contentType: "text/plain; charset=utf-8", fileName: "a.txt"), .text)
        XCTAssertEqual(AttachmentKind(contentType: "text/csv; charset=utf-8", fileName: "a.csv"), .spreadsheet)
        XCTAssertEqual(AttachmentKind(contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", fileName: "a.docx"), .document)
        XCTAssertEqual(AttachmentKind(contentType: "application/vnd.ms-powerpoint", fileName: "a.ppt"), .presentation)
        XCTAssertEqual(AttachmentKind(contentType: "application/octet-stream", fileName: "a"), .other)
        for kind in AttachmentKind.allCases {
            XCTAssertFalse(kind.systemImage.isEmpty)
            XCTAssertFalse(kind.arabicName.isEmpty)
        }
    }

    func testChecksMatchTheServer() {
        let max = AttachmentRules.maxFileBytes
        XCTAssertNil(AttachmentRules.check(fileName: "عقد.PDF", size: 1200))
        XCTAssertNil(AttachmentRules.check(fileName: "صورة.heic", size: max))
        XCTAssertEqual(AttachmentRules.check(fileName: "page.html", size: 10), .wrongType)
        XCTAssertEqual(AttachmentRules.check(fileName: "logo.svg", size: 10), .wrongType)
        XCTAssertEqual(AttachmentRules.check(fileName: "فارغ.txt", size: 0), .empty)
        XCTAssertEqual(AttachmentRules.check(fileName: "كبير.pdf", size: max + 1), .tooLarge(maxBytes: max))
        XCTAssertEqual(AttachmentRules.mimeType(forFileName: "a.JPG"), "image/jpeg")
        XCTAssertEqual(AttachmentRules.mimeType(forFileName: "a.docx"), "application/octet-stream")
    }

    func testArabicText() {
        XCTAssertEqual(AttachmentText.count(0, locale: ar), "لا مرفقات")
        XCTAssertEqual(AttachmentText.count(1, locale: ar), "مرفق واحد")
        XCTAssertEqual(AttachmentText.count(2, locale: ar), "مرفقان")
        XCTAssertEqual(AttachmentText.count(3, locale: ar), "٣ مرفقات")
        XCTAssertEqual(AttachmentText.count(11, locale: ar), "١١ مرفقاً")
        XCTAssertEqual(AttachmentText.count(100, locale: ar), "١٠٠ مرفق")
        XCTAssertTrue(AttachmentText.limits(maxFileBytes: AttachmentRules.maxFileBytes, locale: ar).contains("٢٥ ميغابايت"))
        XCTAssertTrue(AttachmentText.message(for: .tooLarge(maxBytes: AttachmentRules.maxFileBytes), locale: ar).contains("٢٥ ميغابايت"))

        let full = APIError(status: 413, code: "storage_quota_exceeded", message: "Attachment storage is full")
        XCTAssertTrue(AttachmentText.message(for: full, locale: ar).contains("امتلأت"))
        let viewer = APIError(status: 403, code: "forbidden", message: "")
        XCTAssertTrue(AttachmentText.message(for: viewer, locale: ar).contains("صلاحية"))
        XCTAssertTrue(AttachmentText.message(for: URLError(.notConnectedToInternet), locale: ar).contains("اتصال"))
    }
}
