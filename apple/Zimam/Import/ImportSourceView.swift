import SwiftUI
import UniformTypeIdentifiers
import ZimamKit

/// One server source: how to export from the other app, then a file to upload or a token to
/// paste. Once the server takes the job, the screen follows it (`ImportJobView`).
struct ImportSourceView: View {
    let source: ImportSource
    let maxFileBytes: Int
    /// Tells the import screen about a job started here, for its history.
    let onStarted: (ImportJob) -> Void

    @Environment(SessionStore.self) private var session

    @State private var job: ImportJob?
    @State private var choosingFile = false
    @State private var token = ""
    @State private var isStarting = false
    @State private var errorMessage: String?
    /// The import already running when the server answers 409, so the user can follow it instead.
    @State private var runningJob: ImportJob?
    /// The server answered `pro_required` (only when it enforces plans): offer the paywall.
    @State private var needsPro = false
    @State private var showingPaywall = false

    init(source: ImportSource, maxFileBytes: Int, onStarted: @escaping (ImportJob) -> Void = { _ in }) {
        self.source = source
        self.maxFileBytes = maxFileBytes
        self.onStarted = onStarted
    }

    private var locale: Locale { ZimamLocale.current }

    var body: some View {
        if let job {
            ImportJobView(job: job)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                Text(ImportText.howTo(source: source.id))
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                if source.input == .token {
                    Link(destination: ImportText.todoistTokenURL) {
                        Label("فتح إعدادات المطوّر في Todoist", systemImage: "arrow.up.forward.square")
                    }
                    .frame(minHeight: ZimamSpacing.space11)
                }
            }

            switch source.input {
            case .file: fileSection
            case .token: tokenSection
            case .unsupported: EmptyView()
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ZimamColor.priorityHigh)
                    if let runningJob {
                        Button("متابعة الاستيراد الجاري", systemImage: "arrow.triangle.2.circlepath") {
                            job = runningJob
                        }
                        .frame(minHeight: ZimamSpacing.space11)
                    }
                    if needsPro {
                        Button("الاشتراك", systemImage: "star") { showingPaywall = true }
                            .frame(minHeight: ZimamSpacing.space11)
                    }
                }
            }
        }
        .sheet(isPresented: $showingPaywall) { PaywallView() }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle(ImportText.title(forSource: source.id, label: source.label))
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: contentTypes) { result in
            switch result {
            case .success(let url):
                Task { await upload(url) }
            case .failure:
                errorMessage = "تعذّر فتح الملف. اختره مرة أخرى."
            }
        }
    }

    private var fileSection: some View {
        Section {
            Button {
                errorMessage = nil
                choosingFile = true
            } label: {
                HStack(spacing: ZimamSpacing.space2) {
                    if isStarting { ProgressView() }
                    Text(isStarting ? "جارٍ الرفع…" : "اختيار ملف")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.zimamPrimary)
            .disabled(isStarting)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            Text("\(ImportText.limit(maxFileBytes, locale: locale)) الأنواع: \(extensionsText).")
        }
    }

    private var tokenSection: some View {
        Section {
            SecureField("رمز API من Todoist", text: $token)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .frame(minHeight: ZimamSpacing.space11)
                .onSubmit { Task { await startWithToken() } }
            Button {
                Task { await startWithToken() }
            } label: {
                HStack(spacing: ZimamSpacing.space2) {
                    if isStarting { ProgressView() }
                    Text(isStarting ? "جارٍ البدء…" : "بدء الاستيراد")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.zimamPrimary)
            .disabled(isStarting || trimmedToken.count < 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("الرمز")
        } footer: {
            Text("يُرسل الرمز إلى خادم زمام مرة واحدة ليقرأ مهامك من Todoist، ولا يُحفظ في التطبيق ولا في الخادم.")
        }
    }

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var extensionsText: String {
        source.extensions.map { $0.replacingOccurrences(of: ".", with: "").uppercased() }.joined(separator: "، ")
    }

    /// The file types the picker offers, from the source's extensions.
    private var contentTypes: [UTType] {
        let types = source.extensions.compactMap { ext -> UTType? in
            switch ext {
            case ".csv": return .commaSeparatedText
            case ".tsv": return .tabSeparatedText
            case ".txt": return .plainText
            case ".json": return .json
            default: return UTType(filenameExtension: String(ext.dropFirst()))
            }
        }
        return types.isEmpty ? [.data] : types
    }

    // MARK: Starting

    private func upload(_ url: URL) async {
        errorMessage = nil
        runningJob = nil
        let name = url.lastPathComponent
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // Refuse a file that is too large before reading it.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           let problem = ImportText.check(fileName: name, size: size, source: source, maxFileBytes: maxFileBytes) {
            errorMessage = ImportText.message(for: problem, locale: locale)
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            errorMessage = "تعذّرت قراءة الملف. اختره مرة أخرى."
            return
        }
        if let problem = ImportText.check(fileName: name, size: data.count, source: source, maxFileBytes: maxFileBytes) {
            errorMessage = ImportText.message(for: problem, locale: locale)
            return
        }

        isStarting = true
        defer { isStarting = false }
        do {
            started(try await session.api.startImport(source: source.id, fileName: name, data: data))
        } catch {
            await show(error)
        }
    }

    private func startWithToken() async {
        let value = trimmedToken
        guard value.count >= 8, !isStarting else { return }
        errorMessage = nil
        runningJob = nil
        // Sent once and forgotten: the field is cleared before the request goes out.
        token = ""
        isStarting = true
        defer { isStarting = false }
        do {
            started(try await session.api.startImport(source: source.id, token: value))
        } catch {
            await show(error)
        }
    }

    private func started(_ newJob: ImportJob) {
        onStarted(newJob)
        job = newJob
    }

    private func show(_ error: Error) async {
        needsPro = APIError.requiresPro(error)
        if let apiError = error as? APIError, apiError.code == "invalid", source.input == .token {
            errorMessage = "الرمز غير صالح. انسخه كاملاً من إعدادات المطوّر في Todoist."
            return
        }
        errorMessage = ImportText.message(for: error, maxFileBytes: maxFileBytes, expected: source.extensions, locale: locale)
        if (error as? APIError)?.code == "import_in_progress" {
            runningJob = try? await session.api.imports().first { !$0.isFinished }
        }
    }
}
