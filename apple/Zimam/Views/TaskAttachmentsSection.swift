import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import ZimamKit

// «المرفقات» in a task's details. The list comes from the server when the task opens
// (GET /v1/tasks/:id/attachments) and after each sync; files download on demand and open
// in Quick Look. Neither is kept in SwiftData: the last list and the opened files stay in
// the Caches folder (`AttachmentCache`), so offline the list shows and what was opened
// before still opens. api/DEVELOPMENT.md («المرفقات») explains why.

/// The task's attachments, with adding from Files or Photos, preview, share and delete.
struct TaskAttachmentsSection: View {
    let task: TaskItem

    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync

    @State private var list: TaskAttachments?
    @State private var problem: String?
    @State private var uploading = false
    @State private var opening: UUID?
    /// The file Quick Look shows, and whose row presents it.
    @State private var preview: Preview?
    @State private var deleting: TaskAttachment?
    @State private var choosingFile = false
    @State private var photoItem: PhotosPickerItem?
    /// Bumped when a file lands in the cache, so rows offer «مشاركة» for it.
    @State private var cacheVersion = 0

    private var locale: Locale { ZimamLocale.current }
    private var maxFileBytes: Int { list?.maxFileBytes ?? AttachmentRules.maxFileBytes }

    var body: some View {
        let online = NetworkMonitor.shared.isOnline
        Section {
            ForEach(list?.attachments ?? []) { attachment in
                // One file-system check per row, not two.
                let cached = cachedURL(for: attachment)
                AttachmentRow(
                    attachment: attachment,
                    cachedURL: cached,
                    isOpening: opening == attachment.id,
                    canOpen: online || cached != nil,
                    canDelete: online && attachment.canDelete == true,
                    onOpen: { Task { await open(attachment) } },
                    onDelete: { deleting = attachment }
                )
                // Presented from the row that asked, which is on screen.
                .quickLookPreview(previewBinding(for: attachment))
                .confirmationDialog("حذف المرفق؟", isPresented: deletingBinding(for: attachment), titleVisibility: .visible) {
                    Button("حذف", role: .destructive) { delete(attachment) }
                    Button("إلغاء", role: .cancel) {}
                } message: {
                    Text("يُحذف «\(attachment.fileName)» من المهمة عند كل من يراها.")
                }
            }
            // One row that is always there holds the status and the add buttons, with what
            // they present and the loading, so these are attached once and not to every row.
            controls(online: online)
                .task(id: task.id) { await load() }
                .onChange(of: sync.lastSyncedAt) { _, _ in
                    Task { await load(quietly: true) }
                }
                .onChange(of: online) { _, isOnline in
                    if isOnline { Task { await load() } }
                }
                .onChange(of: photoItem) { _, item in
                    guard let item else { return }
                    photoItem = nil
                    Task { await importPhoto(item) }
                }
                .fileImporter(isPresented: $choosingFile, allowedContentTypes: contentTypes) { result in
                    switch result {
                    case .success(let url):
                        Task { await importFile(url) }
                    case .failure:
                        problem = "تعذّر فتح الملف. اختره مرة أخرى."
                    }
                }
        } header: {
            Text("المرفقات")
        } footer: {
            if online {
                Text(AttachmentText.limits(maxFileBytes: maxFileBytes, locale: locale))
            } else {
                Text("دون اتصال تظهر المرفقات المعروفة، ويُفتح ما فُتح منها من قبل. الإضافة والحذف يحتاجان الاتصال.")
            }
        }
    }

    // MARK: The controls row

    @ViewBuilder
    private func controls(online: Bool) -> some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            if list == nil && online && problem == nil {
                AssistantStatus(phase: .loading("تُحمَّل المرفقات…"))
            } else if let list, list.attachments.isEmpty {
                Text("لا مرفقات بعد.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .frame(minHeight: ZimamSpacing.space11)
            } else if let list {
                Text(AttachmentText.count(list.attachments.count, locale: locale))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            if list?.canAdd ?? true {
                Button {
                    problem = nil
                    choosingFile = true
                } label: {
                    HStack(spacing: ZimamSpacing.space2) {
                        if uploading { ProgressView() }
                        Label(uploading ? "جارٍ الرفع…" : "إضافة من الملفات", systemImage: "doc.badge.plus")
                    }
                    .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!online || uploading)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("إضافة من الصور", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!online || uploading)
            } else {
                Text("يضيف المرفقات مالك المشروع ومحرروه.")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
    }

    private struct Preview: Equatable {
        let id: UUID
        let url: URL
    }

    private func previewBinding(for attachment: TaskAttachment) -> Binding<URL?> {
        Binding(
            get: { preview?.id == attachment.id ? preview?.url : nil },
            set: { if $0 == nil { preview = nil } }
        )
    }

    private func deletingBinding(for attachment: TaskAttachment) -> Binding<Bool> {
        Binding(
            get: { deleting?.id == attachment.id },
            set: { if !$0, deleting?.id == attachment.id { deleting = nil } }
        )
    }

    /// The types the Files picker offers: what the server accepts.
    private var contentTypes: [UTType] {
        let types = AttachmentRules.extensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.item] : types
    }

    private func cachedURL(for attachment: TaskAttachment) -> URL? {
        _ = cacheVersion
        return AttachmentCache.cachedFile(for: attachment)
    }

    // MARK: Loading

    private func load(quietly: Bool = false) async {
        if list == nil { list = AttachmentCache.list(for: task.id) }
        guard NetworkMonitor.shared.isOnline else { return }
        do {
            let fresh = try await session.api.attachments(on: task.id)
            list = fresh
            AttachmentCache.saveList(fresh, for: task.id)
            problem = nil
        } catch let error as APIError where error.status == 404 {
            // A new task that has not reached the server yet has no attachments.
            if list == nil { list = TaskAttachments(attachments: [], maxFileBytes: AttachmentRules.maxFileBytes, canAdd: true) }
        } catch {
            if !quietly { problem = AttachmentText.message(for: error, maxFileBytes: maxFileBytes, locale: locale) }
        }
    }

    // MARK: Adding

    private func importFile(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        // Refuse a file that is too large before reading it.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           let found = AttachmentRules.check(fileName: name, size: size, maxFileBytes: maxFileBytes) {
            problem = AttachmentText.message(for: found, locale: locale)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            problem = "تعذّرت قراءة الملف. اختره مرة أخرى."
            return
        }
        await upload(fileName: name, data: data)
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        // The photo's own format (HEIC, JPEG, PNG…), as long as the server takes it.
        guard let type = item.supportedContentTypes.first(where: { candidate in
            AttachmentRules.extensions.contains(candidate.preferredFilenameExtension?.lowercased() ?? "")
        }), let ext = type.preferredFilenameExtension else {
            problem = AttachmentText.message(for: .wrongType, locale: locale)
            return
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                problem = "تعذّرت قراءة الصورة. اخترها مرة أخرى."
                return
            }
            await upload(fileName: "صورة \(Self.photoStamp()).\(ext.lowercased())", data: data)
        } catch {
            problem = "تعذّرت قراءة الصورة. اخترها مرة أخرى."
        }
    }

    /// «٢٠٢٦-١٠-١٥ ٠٩.٣٠.١٢», in the digits the user chose.
    private static func photoStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = ZimamLocale.current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    private func upload(fileName: String, data: Data) async {
        if let found = AttachmentRules.check(fileName: fileName, size: data.count, maxFileBytes: maxFileBytes) {
            problem = AttachmentText.message(for: found, locale: locale)
            return
        }
        problem = nil
        uploading = true
        defer { uploading = false }
        // The server needs the task before it can hold its files.
        if task.isDirty { await sync.sync() }
        do {
            let created = try await session.api.uploadAttachment(fileName: fileName, data: data, to: task.id)
            // Kept, so it opens at once and offline.
            if (try? AttachmentCache.store(data, for: created)) != nil { cacheVersion += 1 }
            var current = list ?? TaskAttachments(attachments: [], maxFileBytes: maxFileBytes, canAdd: true)
            current.attachments.append(created)
            withAnimation { list = current }
            AttachmentCache.saveList(current, for: task.id)
        } catch {
            problem = AttachmentText.message(for: error, maxFileBytes: maxFileBytes, locale: locale)
        }
    }

    // MARK: Opening and deleting

    private func open(_ attachment: TaskAttachment) async {
        if let cached = AttachmentCache.cachedFile(for: attachment) {
            preview = Preview(id: attachment.id, url: cached)
            return
        }
        guard NetworkMonitor.shared.isOnline else {
            problem = "افتح المرفق حين يعود الاتصال."
            return
        }
        opening = attachment.id
        defer { opening = nil }
        do {
            let data = try await session.api.downloadAttachment(attachment.id)
            preview = Preview(id: attachment.id, url: try AttachmentCache.store(data, for: attachment))
            cacheVersion += 1
            problem = nil
        } catch {
            problem = AttachmentText.message(for: error, maxFileBytes: maxFileBytes, locale: locale)
        }
    }

    private func delete(_ attachment: TaskAttachment) {
        deleting = nil
        Task {
            do {
                try await session.api.deleteAttachment(attachment.id)
                AttachmentCache.remove(attachment)
                if var current = list {
                    current.attachments.removeAll { $0.id == attachment.id }
                    withAnimation { list = current }
                    AttachmentCache.saveList(current, for: task.id)
                }
                problem = nil
            } catch {
                problem = AttachmentText.message(for: error, maxFileBytes: maxFileBytes, locale: locale)
            }
        }
    }
}

// MARK: Row

private struct AttachmentRow: View {
    let attachment: TaskAttachment
    let cachedURL: URL?
    let isOpening: Bool
    let canOpen: Bool
    let canDelete: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            Button(action: onOpen) {
                HStack(spacing: ZimamSpacing.space2) {
                    Image(systemName: attachment.kind.systemImage)
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .frame(minWidth: ZimamSpacing.space11, minHeight: ZimamSpacing.space11)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                        Text(attachment.fileName)
                            .font(ZimamType.body)
                            .foregroundStyle(canOpen ? ZimamColor.ink : ZimamColor.inkFaint)
                            .lineLimit(2)
                        Text(AttachmentText.meta(attachment, locale: ZimamLocale.current))
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isOpening { ProgressView() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!canOpen || isOpening)
            .accessibilityElement(children: .combine)
            .accessibilityHint(canOpen ? "يفتح المرفق" : "يحتاج الاتصال بالإنترنت")

            if cachedURL != nil || canDelete {
                Menu {
                    if let cachedURL {
                        ShareLink(item: cachedURL) {
                            Label("مشاركة", systemImage: "square.and.arrow.up")
                        }
                    }
                    if canDelete {
                        Button("حذف", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(ZimamColor.inkMuted)
                        .frame(minWidth: ZimamSpacing.space11, minHeight: ZimamSpacing.space11)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("خيارات المرفق \(attachment.fileName)")
            }
        }
    }
}

// MARK: Cache

/// The last attachment list of each task and the files opened, in the Caches folder: the
/// system may clear it, and the app fetches again when online. Cleared on sign-out.
enum AttachmentCache {
    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    private static func folder(for attachment: TaskAttachment) -> URL {
        root.appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(attachment.id.uuidString.lowercased(), isDirectory: true)
    }

    private static func listURL(for taskId: UUID) -> URL {
        root.appendingPathComponent("lists", isDirectory: true)
            .appendingPathComponent("\(taskId.uuidString.lowercased()).json")
    }

    /// The file under its own name, so Quick Look and sharing show it.
    private static func fileURL(for attachment: TaskAttachment) -> URL {
        let name = attachment.fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return folder(for: attachment).appendingPathComponent(name.isEmpty ? "file" : name)
    }

    static func cachedFile(for attachment: TaskAttachment) -> URL? {
        let url = fileURL(for: attachment)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func store(_ data: Data, for attachment: TaskAttachment) throws -> URL {
        let url = fileURL(for: attachment)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func remove(_ attachment: TaskAttachment) {
        try? FileManager.default.removeItem(at: folder(for: attachment))
    }

    static func list(for taskId: UUID) -> TaskAttachments? {
        guard let data = try? Data(contentsOf: listURL(for: taskId)) else { return nil }
        return try? JSONDecoder().decode(TaskAttachments.self, from: data)
    }

    static func saveList(_ list: TaskAttachments, for taskId: UUID) {
        let url = listURL(for: taskId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
    }

    /// Everything, on sign-out: the files belong to the account that opened them.
    static func clearAll() {
        try? FileManager.default.removeItem(at: root)
    }
}
