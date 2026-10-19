import Foundation
import Testing
@testable import ZimamKit

struct AttachmentsTests {
    let ar = Locale(identifier: "ar-SA")

    @Test func decodesTheList() throws {
        let json = """
        {"attachments":[{"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","taskId":"1f0e2d3c-4b5a-4968-8776-655443322110",
          "projectId":null,"uploaderId":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","uploaderName":"سارة",
          "fileName":"عقد الإيجار.pdf","contentType":"application/pdf","size":2048,
          "createdAt":1760000000000,"updatedAt":1760000000000,"canDelete":true}],
         "maxFileBytes":26214400,"canAdd":false}
        """
        let list = try JSONDecoder().decode(TaskAttachments.self, from: Data(json.utf8))
        #expect(!list.canAdd)
        #expect(list.maxFileBytes == AttachmentRules.maxFileBytes)
        let attachment = try #require(list.attachments.first)
        #expect(attachment.id == UUID(uuidString: "2A3B4C5D-6E7F-4801-9234-56789ABCDEF0"))
        #expect(attachment.projectId == nil)
        #expect(attachment.fileName == "عقد الإيجار.pdf")
        #expect(attachment.kind == .pdf)
        #expect(attachment.canDelete == true)

        // Kept in the Caches folder as JSON, and read back the same.
        let again = try JSONDecoder().decode(TaskAttachments.self, from: JSONEncoder().encode(list))
        #expect(again == list)

        // An upload's answer, and a sync row, may come without canDelete or a name.
        let bare = try JSONDecoder().decode(TaskAttachment.self, from: Data("""
        {"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","taskId":"1f0e2d3c-4b5a-4968-8776-655443322110",
         "projectId":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","uploaderId":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f",
         "fileName":"صورة.heic","contentType":"image/heic","size":10,"createdAt":1,"updatedAt":1}
        """.utf8))
        #expect(bare.canDelete == nil)
        #expect(bare.uploaderName == nil)
        #expect(bare.kind == .image)
    }

    @Test func kinds() {
        #expect(AttachmentKind(contentType: "image/jpeg", fileName: "a.jpg") == .image)
        #expect(AttachmentKind(contentType: "text/plain; charset=utf-8", fileName: "a.txt") == .text)
        #expect(AttachmentKind(contentType: "text/csv; charset=utf-8", fileName: "a.csv") == .spreadsheet)
        #expect(AttachmentKind(contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", fileName: "a.docx") == .document)
        #expect(AttachmentKind(contentType: "application/vnd.ms-powerpoint", fileName: "a.ppt") == .presentation)
        #expect(AttachmentKind(contentType: "application/octet-stream", fileName: "a") == .other)
        for kind in AttachmentKind.allCases {
            #expect(!kind.systemImage.isEmpty)
            #expect(!kind.arabicName.isEmpty)
        }
    }

    @Test func checksMatchTheServer() {
        let max = AttachmentRules.maxFileBytes
        #expect(AttachmentRules.check(fileName: "عقد.PDF", size: 1200) == nil)
        #expect(AttachmentRules.check(fileName: "صورة.heic", size: max) == nil)
        #expect(AttachmentRules.check(fileName: "page.html", size: 10) == .wrongType)
        #expect(AttachmentRules.check(fileName: "logo.svg", size: 10) == .wrongType)
        #expect(AttachmentRules.check(fileName: "فارغ.txt", size: 0) == .empty)
        #expect(AttachmentRules.check(fileName: "كبير.pdf", size: max + 1) == .tooLarge(maxBytes: max))
        #expect(AttachmentRules.mimeType(forFileName: "a.JPG") == "image/jpeg")
        #expect(AttachmentRules.mimeType(forFileName: "a.docx") == "application/octet-stream")
    }

    @Test func arabicText() {
        #expect(AttachmentText.count(0, locale: ar) == "لا مرفقات")
        #expect(AttachmentText.count(1, locale: ar) == "مرفق واحد")
        #expect(AttachmentText.count(2, locale: ar) == "مرفقان")
        #expect(AttachmentText.count(3, locale: ar) == "٣ مرفقات")
        #expect(AttachmentText.count(11, locale: ar) == "١١ مرفقاً")
        #expect(AttachmentText.count(100, locale: ar) == "١٠٠ مرفق")
        #expect(AttachmentText.limits(maxFileBytes: AttachmentRules.maxFileBytes, locale: ar).contains("٢٥ ميغابايت"))
        #expect(AttachmentText.message(for: .tooLarge(maxBytes: AttachmentRules.maxFileBytes), locale: ar).contains("٢٥ ميغابايت"))

        let full = APIError(status: 413, code: "storage_quota_exceeded", message: "Attachment storage is full")
        #expect(AttachmentText.message(for: full, locale: ar).contains("امتلأت"))
        let viewer = APIError(status: 403, code: "forbidden", message: "")
        #expect(AttachmentText.message(for: viewer, locale: ar).contains("صلاحية"))
        #expect(AttachmentText.message(for: URLError(.notConnectedToInternet), locale: ar).contains("اتصال"))
    }
}
