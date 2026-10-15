import Foundation

// Imports from other apps (api/DEVELOPMENT.md, «الاستيراد»). The server reads the file or the
// Todoist token on its queue and writes the records through sync, so the app only starts a job,
// follows it, and shows what happened. Apple Reminders are imported on the device instead
// (AppleReminders.swift).

/// `GET /v1/imports/sources`: what the server can import, and the upload limit.
public struct ImportSources: Decodable, Equatable, Sendable {
    public let maxFileBytes: Int
    public let sources: [ImportSource]

    public init(maxFileBytes: Int, sources: [ImportSource]) {
        self.maxFileBytes = maxFileBytes
        self.sources = sources
    }
}

public struct ImportSource: Decodable, Equatable, Hashable, Identifiable, Sendable {
    /// How the source is read: an uploaded file, or a token the user pastes.
    /// Sources the app does not know yet (OAuth later) decode as `.unsupported` and are hidden.
    public enum Input: String, Sendable {
        case file, token, unsupported
    }

    /// Stable id: "todoist-csv", "todoist-api", "ticktick-csv", "google-tasks", "csv".
    public let id: String
    /// The provider's name as the server gives it ("Todoist", "TickTick").
    public let label: String
    public let input: Input
    /// Lowercase with the dot (".csv"), for file sources.
    public let extensions: [String]

    public init(id: String, label: String, input: Input, extensions: [String] = []) {
        self.id = id
        self.label = label
        self.input = input
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey { case id, label, input, extensions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        input = Input(rawValue: try c.decode(String.self, forKey: .input)) ?? .unsupported
        extensions = (try c.decodeIfPresent([String].self, forKey: .extensions) ?? []).map { $0.lowercased() }
    }
}

/// One import job as `GET /v1/imports/:id` returns it.
public struct ImportJob: Decodable, Equatable, Identifiable, Sendable {
    public enum Status: String, Sendable {
        case queued, running, done, failed

        /// The job will not change any more.
        public var isFinished: Bool { self == .done || self == .failed }
    }

    public struct Progress: Decodable, Equatable, Sendable {
        public let processed: Int
        /// 0 until the source has been read.
        public let total: Int

        public init(processed: Int, total: Int) {
            self.processed = processed
            self.total = total
        }
    }

    /// Totals over projects, sections, tasks and reminders.
    public struct Counts: Decodable, Equatable, Sendable {
        /// New in Zimam.
        public let created: Int
        /// Changed in the source since the last import, so updated.
        public let updated: Int
        /// Same as last time: nothing written.
        public let unchanged: Int
        /// Edited or deleted in Zimam since the last import: Zimam's version was kept.
        public let skipped: Int
        /// Refused; the reasons are in `errors`.
        public let failed: Int

        public init(created: Int = 0, updated: Int = 0, unchanged: Int = 0, skipped: Int = 0, failed: Int = 0) {
            self.created = created
            self.updated = updated
            self.unchanged = unchanged
            self.skipped = skipped
            self.failed = failed
        }

        private enum CodingKeys: String, CodingKey { case created, updated, unchanged, skipped, failed }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
            updated = try c.decodeIfPresent(Int.self, forKey: .updated) ?? 0
            unchanged = try c.decodeIfPresent(Int.self, forKey: .unchanged) ?? 0
            skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
            failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        }
    }

    /// A record the server could not write. `message` is Arabic, shown as is.
    public struct ItemError: Decodable, Equatable, Hashable, Sendable {
        public let entity: String
        public let title: String
        public let message: String

        public init(entity: String, title: String, message: String) {
            self.entity = entity
            self.title = title
            self.message = message
        }
    }

    /// Why a job failed: a stable English code and an Arabic message shown as is.
    public struct Failure: Decodable, Equatable, Sendable {
        public let code: String
        public let message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    /// Lowercase UUID, as the server writes it; used as is in `GET /v1/imports/:id`.
    public let id: String
    public let source: String
    public let status: Status
    public let fileName: String?
    public let progress: Progress
    public let counts: Counts
    /// Arabic notes on what was not carried over exactly.
    public let warnings: [String]
    public let errors: [ItemError]
    public let error: Failure?
    public let createdAt: Milliseconds
    public let updatedAt: Milliseconds
    public let finishedAt: Milliseconds?

    public var isFinished: Bool { status.isFinished }

    public init(id: String, source: String, status: Status, fileName: String? = nil, progress: Progress = .init(processed: 0, total: 0),
                counts: Counts = .init(), warnings: [String] = [], errors: [ItemError] = [], error: Failure? = nil,
                createdAt: Milliseconds = 0, updatedAt: Milliseconds = 0, finishedAt: Milliseconds? = nil) {
        self.id = id
        self.source = source
        self.status = status
        self.fileName = fileName
        self.progress = progress
        self.counts = counts
        self.warnings = warnings
        self.errors = errors
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, status, fileName, progress, counts, warnings, errors, error, createdAt, updatedAt, finishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        // A status this version does not know is treated as still running, so it is followed, not misread as done.
        status = Status(rawValue: try c.decode(String.self, forKey: .status)) ?? .running
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        progress = try c.decodeIfPresent(Progress.self, forKey: .progress) ?? Progress(processed: 0, total: 0)
        counts = try c.decodeIfPresent(Counts.self, forKey: .counts) ?? Counts()
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        errors = try c.decodeIfPresent([ItemError].self, forKey: .errors) ?? []
        error = try c.decodeIfPresent(Failure.self, forKey: .error)
        createdAt = try c.decode(Milliseconds.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Milliseconds.self, forKey: .updatedAt) ?? createdAt
        finishedAt = try c.decodeIfPresent(Milliseconds.self, forKey: .finishedAt)
    }
}

// MARK: - Multipart upload

/// A `multipart/form-data` body: text fields, then one file. Built in memory: uploads are at most
/// a few megabytes (`ImportSources.maxFileBytes`).
public struct MultipartForm: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "zimam-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.quoted(name))\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    public mutating func addFile(_ name: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.quoted(name))\"; filename=\"\(Self.quoted(fileName))\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// The finished body, closed with the last boundary.
    public var data: Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    private mutating func append(_ text: String) {
        body.append(Data(text.utf8))
    }

    /// Header parameter values cannot hold quotes or line breaks; the file name is UTF-8, as browsers send it.
    static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// The media type for an upload, from its extension.
    public static func mimeType(forFileName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "csv": return "text/csv"
        case "tsv": return "text/tab-separated-values"
        case "txt": return "text/plain"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Checks and Arabic text

/// What is wrong with a file before it is sent, as the server would refuse it.
public enum ImportFileProblem: Equatable, Sendable {
    case empty
    case tooLarge(maxBytes: Int)
    case wrongType(expected: [String])
}

/// One line of a job's counts.
public struct ImportCountRow: Equatable, Identifiable, Sendable {
    public let label: String
    public let value: Int
    public var id: String { label }

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

public enum ImportText {
    /// Checks a chosen file against the source and the server's limit (the same rules as `POST /v1/imports`).
    public static func check(fileName: String, size: Int, source: ImportSource, maxFileBytes: Int) -> ImportFileProblem? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty, !source.extensions.isEmpty, !source.extensions.contains("." + ext) {
            return .wrongType(expected: source.extensions)
        }
        if size == 0 { return .empty }
        if size > maxFileBytes { return .tooLarge(maxBytes: maxFileBytes) }
        return nil
    }

    /// «٥ ميغابايت», «٥٠٠ كيلوبايت».
    public static func size(_ bytes: Int, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1 {
            return "\(mb.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) ميغابايت"
        }
        let kb = max(1, Int((Double(bytes) / 1024).rounded()))
        return "\(kb.formatted(.number.locale(locale))) كيلوبايت"
    }

    /// The file limit as the sources screen states it.
    public static func limit(_ maxFileBytes: Int, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        "حجم الملف حتى \(size(maxFileBytes, locale: locale))."
    }

    public static func message(for problem: ImportFileProblem, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        switch problem {
        case .empty:
            return "الملف فارغ. صدّره مرة أخرى ثم اختره."
        case .tooLarge(let maxBytes):
            return "الملف أكبر من الحد المسموح (\(size(maxBytes, locale: locale))). قسّمه إلى ملفات أصغر أو استورد المهام المفتوحة فقط."
        case .wrongType(let expected):
            return "هذا المصدر يقبل ملفات \(expected.map { $0.uppercased().replacingOccurrences(of: ".", with: "") }.joined(separator: " أو ")) فقط."
        }
    }

    /// Arabic text for an error from `POST /v1/imports` and friends. The server's codes are stable and English.
    public static func message(for error: Error, maxFileBytes: Int? = nil, expected: [String] = [],
                               locale: Locale = Locale(identifier: "ar-SA")) -> String {
        guard let error = error as? APIError else {
            return "تعذّر الاتصال بزمام. تحقّق من الإنترنت وحاول مرة أخرى."
        }
        switch error.code {
        case "file_too_large":
            return message(for: .tooLarge(maxBytes: maxFileBytes ?? 5 * 1024 * 1024), locale: locale)
        case "invalid_file_type":
            return expected.isEmpty ? "نوع الملف لا يناسب هذا المصدر." : message(for: .wrongType(expected: expected), locale: locale)
        case "empty_file":
            return message(for: .empty, locale: locale)
        case "invalid_source":
            return "هذا المصدر غير متاح. حدّث التطبيق ثم حاول مرة أخرى."
        case "invalid":
            return "تعذّر قراءة الطلب. تحقّق من الملف أو الرمز ثم حاول مرة أخرى."
        case "import_in_progress":
            return "يجري استيراد آخر الآن. انتظر حتى ينتهي ثم ابدأ استيراداً جديداً."
        case "import_unavailable":
            return "تعذّر بدء الاستيراد الآن. أعد المحاولة بعد قليل."
        case "pro_required":
            return "الاستيراد من هذا المصدر من مزايا «زمام الاحترافية». تذكيرات أبل تبقى مجانية."
        case "not_found":
            return "لم نجد هذا الاستيراد."
        case "unauthorized":
            return "انتهت الجلسة. سجّل الدخول مرة أخرى."
        default:
            return error.status >= 500 || error.status == 0
                ? "حدث خطأ في الخادم. حاول بعد قليل."
                : "تعذّر الاستيراد. حاول مرة أخرى."
        }
    }

    public static func status(_ status: ImportJob.Status) -> String {
        switch status {
        case .queued: return "في الانتظار"
        case .running: return "جارٍ الاستيراد"
        case .done: return "اكتمل"
        case .failed: return "تعذّر"
        }
    }

    /// «٥٠ من ١٢١», or what happens before the total is known.
    public static func progress(_ job: ImportJob, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        if job.status == .queued { return "ينتظر دوره في الطابور…" }
        guard job.progress.total > 0 else { return "تُقرأ البيانات…" }
        let processed = min(job.progress.processed, job.progress.total)
        return "\(processed.formatted(.number.locale(locale))) من \(job.progress.total.formatted(.number.locale(locale)))"
    }

    /// 0...1 for a progress bar, or nil while the total is unknown.
    public static func fraction(_ job: ImportJob) -> Double? {
        if job.status == .done { return 1 }
        guard job.progress.total > 0 else { return nil }
        return min(1, Double(job.progress.processed) / Double(job.progress.total))
    }

    /// One line for a finished job: «أُضيف ٤٨ عنصراً، وحُدِّث ٢.»
    public static func summary(_ job: ImportJob, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        if job.status == .failed {
            return job.error?.message ?? "تعذّر الاستيراد."
        }
        guard job.status == .done else { return progress(job, locale: locale) }
        let c = job.counts
        var parts: [String] = []
        if c.created > 0 { parts.append("أُضيف \(items(c.created, locale: locale))") }
        if c.updated > 0 { parts.append("حُدِّث \(items(c.updated, locale: locale))") }
        if parts.isEmpty {
            return c.unchanged + c.skipped > 0 ? "لا جديد: كل شيء موجود في زمام." : "لم يُعثر على ما يُستورد."
        }
        return parts.joined(separator: "، و") + "."
    }

    /// Counted «عنصر» with Arabic agreement: «عنصر واحد»، «عنصران»، «٣ عناصر»، «١١ عنصراً»، «١٠٠ عنصر».
    public static func items(_ n: Int, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        let number = n.formatted(.number.locale(locale))
        switch n {
        case 0: return "لا عناصر"
        case 1: return "عنصر واحد"
        case 2: return "عنصران"
        default:
            let rest = n % 100
            if (3...10).contains(rest) { return "\(number) عناصر" }
            if (11...99).contains(rest) { return "\(number) عنصراً" }
            return "\(number) عنصر"
        }
    }

    /// The count rows a job shows, in order, without the zero ones (the first row when everything is zero).
    public static func countRows(_ counts: ImportJob.Counts) -> [ImportCountRow] {
        let rows = [
            ImportCountRow(label: "أُضيف", value: counts.created),
            ImportCountRow(label: "حُدِّث", value: counts.updated),
            ImportCountRow(label: "لم يتغيّر", value: counts.unchanged),
            ImportCountRow(label: "بقي كما عُدِّل في زمام", value: counts.skipped),
            ImportCountRow(label: "تعذّر", value: counts.failed),
        ]
        let shown = rows.filter { $0.value > 0 }
        return shown.isEmpty ? Array(rows.prefix(1)) : shown
    }

    /// A few words under the source's name in the list.
    public static func subtitle(forSource id: String) -> String {
        switch id {
        case "todoist-csv": return "ملف CSV من «تصدير كقالب»"
        case "todoist-api": return "رمز API، فتُنقل المشاريع كلها"
        case "ticktick-csv": return "ملف النسخة الاحتياطية CSV"
        case "google-tasks": return "ملف Tasks.json من Google Takeout"
        case "csv": return "أي جدول بصيغة CSV"
        case AppleRemindersImport.sourceId: return "من هذا الجهاز مباشرة"
        default: return ""
        }
    }

    /// The import screen's name for a source, with what it brings over.
    public static func title(forSource id: String, label: String) -> String {
        switch id {
        case "todoist-csv": return "Todoist: ملف مشروع"
        case "todoist-api": return "Todoist: كل المشاريع"
        case "ticktick-csv": return "TickTick"
        case "google-tasks": return "Google Tasks"
        case "csv": return "ملف CSV"
        case AppleRemindersImport.sourceId: return "تذكيرات أبل"
        default: return label
        }
    }

    /// How to get the export out of the other app, in a sentence or two.
    public static func howTo(source id: String) -> String {
        switch id {
        case "todoist-csv":
            return "في Todoist افتح المشروع، ثم من قائمته اختر «قوالب» ثم «تصدير كقالب»، واحفظ ملف CSV. كل ملف يصير مشروعاً في زمام. المهام المنجزة ليست في هذا التصدير."
        case "todoist-api":
            return "انسخ رمز API الشخصي من Todoist: «الإعدادات» ثم «التكاملات» ثم «المطوّر»، والصقه هنا. تُنقل المشاريع والأقسام والمهام المفتوحة كلها. يُرسل الرمز مرة واحدة ولا يُحفظ."
        case "ticktick-csv":
            return "في TickTick افتح «الإعدادات» ثم «الحساب» ثم «النسخ الاحتياطي»، ونزّل ملف CSV. تُنقل القوائم والمهام والمنجزة والتكرار والتذكيرات."
        case "google-tasks":
            return "من Google Takeout (takeout.google.com) اختر «Tasks» وحده ثم صدّر، وفك ضغط الملف واختر Tasks.json. كل قائمة تصير مشروعاً."
        case "csv":
            return "أي جدول صفّه الأول أسماء الأعمدة: العنوان (إلزامي)، والملاحظات، والتاريخ، والوقت، والمشروع، والقسم، والأولوية، والحالة، والوسوم. احفظه من Excel أو Numbers أو Google Sheets بصيغة CSV."
        case AppleRemindersImport.sourceId:
            return "تُقرأ القوائم التي تختارها من تذكيرات أبل على هذا الجهاز، فتصير كل قائمة مشروعاً في زمام. لا يُغيَّر شيء في التذكيرات نفسها."
        default:
            return "صدّر مهامك من التطبيق الآخر ثم اختر الملف."
        }
    }

    /// Where the Todoist token is.
    public static let todoistTokenURL = URL(string: "https://app.todoist.com/app/settings/integrations/developer")!
}
