import Foundation

// Task attachments (api/DEVELOPMENT.md, «المرفقات»). The app fetches a task's list when the
// task opens and each file on demand; neither is kept in SwiftData (see the API docs for why).

/// A file on a task, as `GET /v1/tasks/:id/attachments` lists it.
public struct TaskAttachment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var taskId: UUID
    public var projectId: UUID?
    /// Who added it, as the server sends it; kept in the cached list though no screen shows it yet.
    public var uploaderId: UUID?
    public var uploaderName: String?
    public var fileName: String
    /// Set by the server from the extension, e.g. "application/pdf".
    public var contentType: String
    /// Bytes.
    public var size: Int
    public var createdAt: Milliseconds
    public var updatedAt: Milliseconds
    /// Whether this user may delete it: its uploader, or the owner of the task's project.
    public var canDelete: Bool?

    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000) }
    public var kind: AttachmentKind { AttachmentKind(contentType: contentType, fileName: fileName) }
}

/// `GET /v1/tasks/:id/attachments`: the files, the upload limit, and whether this user may add.
public struct TaskAttachments: Codable, Equatable, Sendable {
    public var attachments: [TaskAttachment]
    public var maxFileBytes: Int
    public var canAdd: Bool

    public init(attachments: [TaskAttachment], maxFileBytes: Int, canAdd: Bool) {
        self.attachments = attachments
        self.maxFileBytes = maxFileBytes
        self.canAdd = canAdd
    }
}

/// What kind of file, for its icon and its word.
public enum AttachmentKind: String, Sendable, CaseIterable {
    case image, pdf, text, document, spreadsheet, presentation, other

    public init(contentType: String, fileName: String) {
        let type = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let ext = (fileName as NSString).pathExtension.lowercased()
        if type.hasPrefix("image/") {
            self = .image
        } else if type == "application/pdf" || ext == "pdf" {
            self = .pdf
        } else if ["xls", "xlsx", "csv"].contains(ext) || type.contains("spreadsheet") || type == "application/vnd.ms-excel" {
            self = .spreadsheet
        } else if ["ppt", "pptx"].contains(ext) || type.contains("presentation") || type == "application/vnd.ms-powerpoint" {
            self = .presentation
        } else if ["doc", "docx", "rtf"].contains(ext) || type.contains("word") {
            self = .document
        } else if type.hasPrefix("text/") {
            self = .text
        } else {
            self = .other
        }
    }

    /// An SF Symbol for the row.
    public var systemImage: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.plaintext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.stack"
        case .other: "doc"
        }
    }

    public var arabicName: String {
        switch self {
        case .image: "صورة"
        case .pdf: "PDF"
        case .text: "نص"
        case .document: "مستند"
        case .spreadsheet: "جدول"
        case .presentation: "عرض تقديمي"
        case .other: "ملف"
        }
    }
}

/// What is wrong with a file before it is sent, as the server would refuse it.
public enum AttachmentProblem: Equatable, Sendable {
    case empty
    case tooLarge(maxBytes: Int)
    case wrongType
}

/// The rules of `POST /v1/tasks/:id/attachments` (ATTACHMENT_TYPES in api/src/attachments.ts).
public enum AttachmentRules {
    public static let maxFileBytes = 25 * 1024 * 1024

    /// Extensions the server accepts, without the dot.
    public static let extensions = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif",
        "pdf",
        "txt", "md", "csv", "rtf",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx",
    ]

    public static func check(fileName: String, size: Int, maxFileBytes: Int = maxFileBytes) -> AttachmentProblem? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !extensions.contains(ext) { return .wrongType }
        if size == 0 { return .empty }
        if size > maxFileBytes { return .tooLarge(maxBytes: maxFileBytes) }
        return nil
    }

    /// The media type sent with an upload; the server decides from the extension anyway.
    public static func mimeType(forFileName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }
}

/// Arabic text for attachments.
public enum AttachmentText {
    /// «PDF، ١٫٢ ميغابايت».
    public static func meta(_ attachment: TaskAttachment, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        "\(attachment.kind.arabicName)، \(ImportText.size(attachment.size, locale: locale))"
    }

    /// «مرفق واحد»، «مرفقان»، «٣ مرفقات»، «١١ مرفقاً»، «١٠٠ مرفق» (a task holds up to 100).
    public static func count(_ n: Int, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        let number = n.formatted(.number.locale(locale))
        switch n {
        case 0: return "لا مرفقات"
        case 1: return "مرفق واحد"
        case 2: return "مرفقان"
        default:
            let rest = n % 100
            if (3...10).contains(rest) { return "\(number) مرفقات" }
            if rest >= 11 { return "\(number) مرفقاً" }
            return "\(number) مرفق"
        }
    }

    /// The limits as the section's footer states them.
    public static func limits(maxFileBytes: Int, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        "صور وPDF ونصوص ومستندات Office، حتى \(ImportText.size(maxFileBytes, locale: locale)) للملف."
    }

    public static func message(for problem: AttachmentProblem, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        switch problem {
        case .empty: return "الملف فارغ."
        case .tooLarge(let maxBytes): return "الملف أكبر من الحد المسموح (\(ImportText.size(maxBytes, locale: locale)))."
        case .wrongType: return "هذا النوع غير مدعوم. أرفق صورة أو PDF أو نصاً أو مستند Office."
        }
    }

    /// Arabic text for an error from the attachment routes. The server's codes are stable and English.
    public static func message(for error: Error, maxFileBytes: Int = AttachmentRules.maxFileBytes,
                               locale: Locale = Locale(identifier: "ar-SA")) -> String {
        if NetworkFailure.isOffline(error) { return "لا يوجد اتصال بالإنترنت. المرفقات تحتاج الاتصال." }
        guard let api = error as? APIError else { return "تعذّر الاتصال بزمام. حاول مرة أخرى." }
        switch api.code {
        case "file_too_large": return message(for: .tooLarge(maxBytes: maxFileBytes), locale: locale)
        case "invalid_file_type": return message(for: .wrongType, locale: locale)
        case "empty_file": return message(for: .empty, locale: locale)
        case "storage_quota_exceeded": return "امتلأت مساحة مرفقاتك. احذف مرفقات لا تحتاجها ثم حاول مرة أخرى."
        case "too_many_attachments": return "بلغت المهمة الحد الأعلى من المرفقات."
        case "forbidden": return "لا تملك صلاحية هذا الإجراء على مرفقات المهمة."
        case "not_found": return "لم يُعثر على المرفق. ربما حُذف أو لم تُزامَن المهمة بعد."
        case "unauthorized": return "انتهت الجلسة. سجّل الدخول مرة أخرى."
        default: return api.status >= 500 || api.status == 0 ? "حدث خطأ في الخادم. حاول بعد قليل." : "تعذّر إكمال الطلب. حاول مرة أخرى."
        }
    }
}
