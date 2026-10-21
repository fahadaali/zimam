import Foundation

// Imports from other apps (api/DEVELOPMENT.md, «الاستيراد»). The server reads the file, the
// Todoist token, or a provider's API after its OAuth flow, on its queue, and writes the records
// through sync, so the app only starts a job, follows it, and shows what happened. Apple Reminders
// are imported on the device instead (AppleReminders.swift).

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
    /// How the source is read: an uploaded file, a token the user pastes, or the provider's
    /// OAuth flow (the server's; the app opens it in ASWebAuthenticationSession).
    /// Kinds this version does not know decode as `.unsupported` and are hidden.
    public enum Input: String, Sendable {
        case file, token, oauth, unsupported
    }

    /// Stable id: "todoist-oauth", "todoist-csv", "todoist-api", "ticktick-csv", "google-tasks-api",
    /// "google-tasks", "csv", "google-calendar", "microsoft-todo", "notion", "trello", "asana", "clickup",
    /// "planner", "jira", "linear", "monday", "ticktick-api".
    public let id: String
    /// The provider's name as the server gives it ("Todoist", "TickTick").
    public let label: String
    public let input: Input
    /// Lowercase with the dot (".csv"), for file sources.
    public let extensions: [String]
    /// False for an OAuth source the server is not set up for yet: shown greyed, «غير متاح الآن».
    public let available: Bool

    public init(id: String, label: String, input: Input, extensions: [String] = [], available: Bool = true) {
        self.id = id
        self.label = label
        self.input = input
        self.extensions = extensions
        self.available = available
    }

    private enum CodingKeys: String, CodingKey { case id, label, input, extensions, available }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        input = Input(rawValue: try c.decode(String.self, forKey: .input)) ?? .unsupported
        extensions = (try c.decodeIfPresent([String].self, forKey: .extensions) ?? []).map { $0.lowercased() }
        // Servers before OAuth sources do not send it: everything they list can start.
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? true
    }
}

/// The import screen lists apps, not ways in: each app once, in its group, with its ways in the
/// easiest first (connecting the account, then a file or a token). The web app has the same list
/// (web/public/app/lib/imports.js, IMPORT_GROUPS). Apple Reminders and Apple Calendar are read on
/// the device, so the app adds them to «تطبيقات المهام» and «التقاويم» itself.
public enum ImportCatalog {
    public struct App: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// The ways in the server can start now, the easiest first.
        public let methods: [ImportSource]
    }

    public struct Group: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let apps: [App]
    }

    private static let layout: [(id: String, title: String, apps: [(id: String, name: String, methods: [String])])] = [
        ("tasks", "تطبيقات المهام", [
            ("todoist", "Todoist", ["todoist-oauth", "todoist-api", "todoist-csv"]),
            ("ticktick", "TickTick", ["ticktick-api", "ticktick-csv"]),
            ("google-tasks", "Google Tasks", ["google-tasks-api", "google-tasks"]),
            ("microsoft-todo", "Microsoft To Do", ["microsoft-todo"]),
        ]),
        ("projects", "المشاريع والفرق", [
            ("asana", "Asana", ["asana"]),
            ("trello", "Trello", ["trello"]),
            ("clickup", "ClickUp", ["clickup"]),
            ("notion", "Notion", ["notion"]),
            ("jira", "Jira", ["jira"]),
            ("linear", "Linear", ["linear"]),
            ("monday", "monday.com", ["monday"]),
            ("planner", "Microsoft Planner", ["planner"]),
        ]),
        ("calendars", "التقاويم", [("google-calendar", "Google Calendar", ["google-calendar"])]),
        ("files", "ملف", [("csv", "ملف CSV", ["csv"])]),
    ]

    /// The groups with what the server can start now. A way in it is not set up for is left out,
    /// and an app with none left is not listed; a source this version does not know comes last,
    /// under «أخرى». Groups in `keeping` stay even when empty (the device's own sources go there).
    public static func groups(from sources: [ImportSource], keeping: Set<String> = []) -> [Group] {
        let ready = sources.filter { $0.available && $0.input != .unsupported }
        let byId = Dictionary(ready.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>()
        var groups = layout.map { group in
            Group(id: group.id, title: group.title, apps: group.apps.compactMap { app in
                let methods = app.methods.compactMap { byId[$0] }
                placed.formUnion(methods.map(\.id))
                return methods.isEmpty ? nil : App(id: app.id, name: app.name, methods: methods)
            })
        }
        let rest = ready.filter { !placed.contains($0.id) }
        if !rest.isEmpty {
            groups.append(Group(id: "other", title: "أخرى", apps: rest.map { App(id: $0.id, name: $0.label, methods: [$0]) }))
        }
        return groups.filter { !$0.apps.isEmpty || keeping.contains($0.id) }
    }

    /// A way into an app, in two words.
    public static func methodTitle(_ source: ImportSource) -> String {
        switch source.input {
        case .oauth: "الربط بالحساب"
        case .token: "برمز API"
        case .file: "من ملف"
        case .unsupported: source.label
        }
    }

    /// Under an app's name: its ways in, or what its one way brings.
    public static func subtitle(of app: App) -> String {
        app.methods.count > 1
            ? app.methods.map(methodTitle).joined(separator: " أو ")
            : ImportText.subtitle(forSource: app.methods.first?.id ?? "")
    }

    /// Beside the easiest way in.
    public static let easiest = "الأسهل"
}

/// Where the server's OAuth callback returns: `zimam://import-callback?pending=<id>&source=<id>`
/// when the provider agreed, or `?error=<code>` when it did not (`denied`, `provider_error`).
/// Nothing has started yet: the app asks whether to import into the signed-in account
/// («استيراد بيانات <المصدر> إلى حسابك …؟») and only then confirms (`APIClient.confirmOAuthImport`).
/// Trello's token comes in the fragment (`#token=…`), never the query, and goes back in the confirm.
public enum ImportCallback: Equatable, Sendable {
    case pending(Pending)
    case failure(String)

    public struct Pending: Equatable, Sendable {
        /// The server's random id for the waiting import; single use, ten minutes.
        public let id: String
        /// The source's id ("notion"), for the question; nil from a server that does not send it.
        public let source: String?
        /// Trello's token from the fragment; nil for the other sources.
        public let token: String?

        public init(id: String, source: String? = nil, token: String? = nil) {
            self.id = id
            self.source = source
            self.token = token
        }
    }

    /// The scheme ASWebAuthenticationSession waits for; the app's own (`ZimamWeb.appScheme`).
    public static let scheme = ZimamWeb.appScheme
    public static let host = "import-callback"

    /// Reads the callback; nil for any other URL.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        if let id = items.first(where: { $0.name == "pending" })?.value, Self.isPendingId(id) {
            let rawSource: String? = items.first(where: { $0.name == "source" })?.value
            let source: String? = rawSource.flatMap { Self.isSourceId($0) ? $0 : nil }
            self = .pending(Pending(id: id, source: source, token: Self.fragmentToken(components.percentEncodedFragment)))
        } else if let code = items.first(where: { $0.name == "error" })?.value, !code.isEmpty {
            self = .failure(code)
        } else {
            return nil
        }
    }

    /// The server's pending id: base64url, 43 characters today.
    static func isPendingId(_ text: String) -> Bool {
        (20...200).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func isSourceId(_ text: String) -> Bool {
        (1...40).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// `token=…` in the fragment (Trello), percent-decoded.
    static func fragmentToken(_ fragment: String?) -> String? {
        guard let fragment, !fragment.isEmpty,
              let items = URLComponents(string: "zimam://x?\(fragment)")?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value,
              (1...500).contains(token.count) else { return nil }
        return token
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
        case "source_unavailable":
            return "هذا المصدر غير متاح الآن. حاول لاحقاً أو اختر مصدراً آخر."
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
        case "todoist-oauth": return "كل المشاريع بإذن من حسابك"
        case "todoist-csv": return "ملف CSV من «تصدير كقالب»"
        case "todoist-api": return "رمز API، فتُنقل المشاريع كلها"
        case "ticktick-csv": return "ملف النسخة الاحتياطية CSV"
        case "google-tasks-api": return "القوائم والمهام بحساب Google"
        case "google-tasks": return "ملف Tasks.json من Google Takeout"
        case "csv": return "أي جدول بصيغة CSV"
        case "google-calendar": return "أحداث تقاويمك مهاماً"
        case "microsoft-todo": return "القوائم والمهام بحساب Microsoft"
        case "notion": return "قاعدة بيانات مهام"
        case "trello": return "اللوحات والبطاقات"
        case "asana": return "المشاريع والأقسام والمهام"
        case "clickup": return "المساحات والقوائم والمهام"
        case "planner": return "الخطط وأعمدتها ومهامها"
        case "jira": return "المشاريع والمهام"
        case "linear": return "الفرق والمهام"
        case "monday": return "اللوحات والمجموعات والعناصر"
        case "ticktick-api": return "القوائم والمهام المفتوحة مباشرة"
        case AppleRemindersImport.sourceId: return "من هذا الجهاز مباشرة"
        default: return ""
        }
    }

    /// Under an OAuth source the server cannot start yet.
    public static let unavailable = "غير متاح الآن"

    /// The button that opens the provider's page: «الربط بـ Notion».
    public static func connect(_ source: ImportSource) -> String {
        "الربط بـ \(source.label)"
    }

    /// Arabic text for the error code the OAuth callback returned with (`ImportCallback.failure`).
    public static func oauthMessage(_ code: String) -> String {
        switch code {
        case "denied":
            return "لم يكتمل الإذن، فلم يبدأ الاستيراد. ابدأ مرة أخرى ووافق على الإذن إن أردت النقل."
        case "provider_error":
            return "رفض المصدر طلب الإذن. حاول مرة أخرى بعد قليل."
        case "pro_required":
            return "الاستيراد من هذا المصدر من مزايا «زمام الاحترافية». تذكيرات أبل تبقى مجانية."
        case "import_in_progress":
            return "يجري استيراد آخر الآن. انتظر حتى ينتهي ثم ابدأ استيراداً جديداً."
        case "import_unavailable":
            return "تعذّر بدء الاستيراد الآن. أعد المحاولة بعد قليل."
        default:
            return "تعذّر إكمال الربط بالمصدر. ابدأ الاستيراد مرة أخرى."
        }
    }

    /// The provider's name in the confirmation, from the source id the callback carried.
    public static func providerName(forSource id: String?) -> String? {
        switch id ?? "" {
        case "todoist-oauth": return "Todoist"
        case "google-tasks-api": return "Google Tasks"
        case "google-calendar": return "Google Calendar"
        case "microsoft-todo": return "Microsoft To Do"
        case "notion": return "Notion"
        case "trello": return "Trello"
        case "asana": return "Asana"
        case "clickup": return "ClickUp"
        case "planner": return "Microsoft Planner"
        case "jira": return "Jira"
        case "linear": return "Linear"
        case "monday": return "monday.com"
        case "ticktick-api": return "TickTick"
        default: return nil
        }
    }

    /// The signed-in account as the confirmation names it: «فهد، fahad@example.com», or either alone.
    public static func accountLabel(name: String?, email: String?) -> String? {
        let parts = [name, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "، ")
    }

    /// The question before an OAuth import starts: «استيراد بيانات Notion إلى حسابك فهد؟».
    /// It names the account the data will go to, so data never lands in an account the user
    /// does not recognise (a provider link someone else started).
    public static func confirmQuestion(source: String?, account: String?) -> String {
        let what = providerName(forSource: source).map { "بيانات \($0)" } ?? "البيانات"
        guard let account else { return "استيراد \(what) إلى حسابك؟" }
        return "استيراد \(what) إلى حسابك \(account)؟"
    }

    /// Under the question.
    public static let confirmNote = "تأكّد أن هذا حسابك. إن لم تبدأ هذا الاستيراد بنفسك من زمام فاختر «إلغاء»."

    /// Arabic text for a refused `POST /v1/imports/oauth/confirm`.
    public static func confirmMessage(for error: Error) -> String {
        let code = (error as? APIError)?.code ?? ""
        switch code {
        case "not_found":
            return "انتهت صلاحية الطلب أو لا يخص حسابك. ابدأ الاستيراد مرة أخرى من حسابك في زمام."
        case "expired":
            return "انتهت صلاحية طلب الاستيراد أو استُعمل من قبل. ابدأ الاستيراد مرة أخرى."
        case "invalid_token", "exchange_failed":
            return oauthMessage("exchange_failed")
        default:
            return message(for: error)
        }
    }

    /// The import screen's name for a source, with what it brings over.
    public static func title(forSource id: String, label: String) -> String {
        switch id {
        case "todoist-oauth": return "Todoist: الربط بالحساب"
        case "todoist-csv": return "Todoist: ملف مشروع"
        case "todoist-api": return "Todoist: كل المشاريع"
        case "ticktick-csv": return "TickTick"
        case "google-tasks-api": return "Google Tasks: الربط بالحساب"
        case "google-tasks": return "Google Tasks"
        case "csv": return "ملف CSV"
        case "google-calendar": return "Google Calendar"
        case "microsoft-todo": return "Microsoft To Do"
        case "notion": return "Notion"
        case "trello": return "Trello"
        case "asana": return "Asana"
        case "clickup": return "ClickUp"
        case "planner": return "Microsoft Planner"
        case "jira": return "Jira"
        case "linear": return "Linear"
        case "monday": return "monday.com"
        case "ticktick-api": return "TickTick: الربط بالحساب"
        case AppleRemindersImport.sourceId: return "تذكيرات أبل"
        default: return label
        }
    }

    /// How to get the export out of the other app, in a sentence or two.
    public static func howTo(source id: String) -> String {
        switch id {
        case "todoist-oauth":
            return "تنتقل إلى Todoist لتأذن لزمام بقراءة مهامك، ثم تعود هنا. تُنقل المشاريع والأقسام والمهام المفتوحة كلها، دون نسخ أي رمز."
        case "todoist-csv":
            return "في Todoist افتح المشروع، ثم من قائمته اختر «قوالب» ثم «تصدير كقالب»، واحفظ ملف CSV. كل ملف يصير مشروعاً في زمام. المهام المنجزة ليست في هذا التصدير."
        case "todoist-api":
            return "انسخ رمز API الشخصي من Todoist: «الإعدادات» ثم «التكاملات» ثم «المطوّر»، والصقه هنا. تُنقل المشاريع والأقسام والمهام المفتوحة كلها. يُرسل الرمز مرة واحدة ولا يُحفظ."
        case "ticktick-csv":
            return "في TickTick افتح «الإعدادات» ثم «الحساب» ثم «النسخ الاحتياطي»، ونزّل ملف CSV. تُنقل القوائم والمهام والمنجزة والتكرار والتذكيرات."
        case "google-tasks-api":
            return "تنتقل إلى Google لتأذن لزمام بقراءة مهامك، ثم تعود هنا. تصير كل قائمة مشروعاً، وتُنقل المهام الفرعية والمواعيد والمنجزة. لا يتغيّر شيء في Google Tasks."
        case "google-tasks":
            return "من Google Takeout (takeout.google.com) اختر «Tasks» وحده ثم صدّر، وفك ضغط الملف واختر Tasks.json. كل قائمة تصير مشروعاً."
        case "csv":
            return "أي جدول صفّه الأول أسماء الأعمدة: العنوان (إلزامي)، والملاحظات، والتاريخ، والوقت، والمشروع، والقسم، والأولوية، والحالة، والوسوم. احفظه من Excel أو Numbers أو Google Sheets بصيغة CSV."
        case "google-calendar":
            return "تنتقل إلى Google لتأذن لزمام بقراءة تقويمك، ثم تعود هنا. يصير كل تقويم ظاهر في Google Calendar مشروعاً، وكل حدث من آخر ٣٠ يوماً إلى سنة قادمة مهمة في موعده. لا يتغيّر شيء في تقويمك."
        case "microsoft-todo":
            return "تنتقل إلى Microsoft لتأذن لزمام بقراءة مهامك، ثم تعود هنا. تصير كل قائمة مشروعاً، وقائمة «المهام» صندوق الوارد، وتُنقل الأهمية والمواعيد والتذكيرات والخطوات والمنجزة."
        case "notion":
            return "تنتقل إلى Notion وتختار قاعدة بيانات المهام (أو الصفحة التي فيها) لتشاركها مع زمام، ثم تعود هنا. تصير كل قاعدة مشروعاً: العنوان، والتاريخ، والحالة أو مربع الإنجاز، والأولوية، والوسوم."
        case "trello":
            return "تنتقل إلى Trello لتأذن لزمام بالقراءة، ثم تعود هنا. تصير كل لوحة مشروع كانبان، وقوائمها أعمدة، وبطاقاتها مهام بمواعيدها وتسمياتها وقوائم التحقق."
        case "asana":
            return "تنتقل إلى Asana لتأذن لزمام بالقراءة، ثم تعود هنا. تُنقل المشاريع غير المؤرشفة بأقسامها ومهامها والمهام الفرعية والمواعيد والمنجزة."
        case "clickup":
            return "تنتقل إلى ClickUp لتأذن لزمام وتختار مساحات العمل، ثم تعود هنا. تصير كل مساحة مجلداً، وكل قائمة مشروعاً، وحالاتها المفتوحة أعمدة، وتُنقل المهام الفرعية والمواعيد والأولوية والوسوم والمنجزة. يقرأ زمام فقط ولا يغيّر شيئاً في ClickUp."
        case "planner":
            return "تنتقل إلى Microsoft لتأذن لزمام بقراءة مهامك، ثم تعود هنا. تصير كل خطة لوحة كانبان وأعمدتها أقساماً، وتُنقل المواعيد والأولوية والمنجزة. يحتاج حساب عمل أو دراسة، لأن Planner غير متاح في الحسابات الشخصية."
        case "jira":
            return "تنتقل إلى Atlassian لتأذن لزمام بقراءة Jira وتختار موقعك، ثم تعود هنا. يصير كل مشروع لوحة كانبان وحالاته المفتوحة أعمدة، وتُنقل المهام والفرعية والأولوية والمواعيد والتسميات والوصف والمنجزة."
        case "linear":
            return "تنتقل إلى Linear لتأذن لزمام بالقراءة، ثم تعود هنا. يصير كل فريق لوحة كانبان وحالاته المفتوحة أعمدة، وتُنقل المهام والفرعية والأولوية والمواعيد والتسميات والمنجزة، ويصير مشروع Linear وسماً. المهام الملغاة لا تُنقل."
        case "monday":
            return "تنتقل إلى monday.com لتأذن لزمام بقراءة لوحاتك، ثم تعود هنا. تصير كل لوحة مشروعاً ومجموعاتها أقساماً، وكل عنصر مهمة وعناصره الفرعية مهاماً فرعية، ويُقرأ التاريخ والحالة والأولوية والوسوم من أعمدتها."
        case "ticktick-api":
            return "تنتقل إلى TickTick لتأذن لزمام بقراءة مهامك، ثم تعود هنا. تُنقل القوائم وأعمدة الكانبان والمهام المفتوحة والتكرار والتذكيرات. وللمهام المنجزة استعمل ملف النسخة الاحتياطية."
        case AppleRemindersImport.sourceId:
            return "تُقرأ القوائم التي تختارها من تذكيرات أبل على هذا الجهاز، فتصير كل قائمة مشروعاً في زمام. لا يُغيَّر شيء في التذكيرات نفسها."
        default:
            return "صدّر مهامك من التطبيق الآخر ثم اختر الملف."
        }
    }

    /// Where the Todoist token is.
    public static let todoistTokenURL = URL(string: "https://app.todoist.com/app/settings/integrations/developer")!
}
