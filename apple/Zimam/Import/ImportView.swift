import SwiftUI
import ZimamKit

/// Settings → «استيراد المهام»: the sources (the server's, and Apple Reminders on this device),
/// and the latest imports with their status and dates.
struct ImportView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dateFormatterZimam) private var formatter

    @State private var sources: ImportSources?
    @State private var history: [ImportJob] = []
    @State private var loadError: String?
    @State private var isLoading = false

    private static let fallbackMaxBytes = 5 * 1024 * 1024

    init() {}

    var body: some View {
        Form {
            sourcesSection
            if !history.isEmpty {
                historySection
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle("استيراد المهام")
        // Also on returning from a source or a job, so the history is current.
        .onAppear { Task { await load() } }
        .refreshable { await load() }
    }

    private var serverSources: [ImportSource] {
        (sources?.sources ?? []).filter { $0.input != .unsupported }
    }

    private var sourcesSection: some View {
        Section {
            NavigationLink {
                RemindersImportView()
            } label: {
                SourceRow(id: AppleRemindersImport.sourceId, label: "", systemImage: "checklist")
            }
            ForEach(serverSources) { source in
                NavigationLink {
                    ImportSourceView(source: source, maxFileBytes: sources?.maxFileBytes ?? Self.fallbackMaxBytes) { job in
                        history.removeAll { $0.id == job.id }
                        history.insert(job, at: 0)
                    }
                } label: {
                    SourceRow(id: source.id, label: source.label, systemImage: source.input == .token ? "key" : "doc.text")
                }
            }
            if sources == nil && isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
            }
        } header: {
            Text("من أين تنقل مهامك؟")
        } footer: {
            if let loadError {
                Text(loadError).foregroundStyle(ZimamColor.priorityHigh)
            } else if let sources {
                Text("\(ImportText.limit(sources.maxFileBytes, locale: ZimamLocale.current)) إعادة استيراد البيانات نفسها تحدّث ما تغيّر ولا تكرر المهام.")
            }
        }
    }

    private var historySection: some View {
        Section("آخر عمليات الاستيراد") {
            ForEach(history) { job in
                NavigationLink {
                    ImportJobView(job: job)
                } label: {
                    HistoryRow(job: job, date: dateText(job.createdAt))
                }
            }
        }
    }

    /// Both calendars and the time: «٢ جمادى الأولى، ١٣ أكتوبر، ٣:٠٠ م».
    private func dateText(_ ms: Milliseconds) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let otherYear = !Calendar(identifier: .gregorian).isDate(date, equalTo: Date(), toGranularity: .year)
        return "\(formatter.dual(date, withYear: otherYear))، \(formatter.time(date))"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let api = session.api
        do {
            async let loadedSources = api.importSources()
            async let loadedHistory = api.imports()
            let (newSources, newHistory) = try await (loadedSources, loadedHistory)
            sources = newSources
            history = newHistory
            loadError = nil
        } catch {
            if Task.isCancelled { return }
            loadError = sources == nil
                ? "تعذّر تحميل المصادر. تحقّق من الاتصال واسحب للتحديث."
                : "تعذّر تحديث السجل. تحقّق من الاتصال."
        }
    }
}

private struct SourceRow: View {
    let id: String
    let label: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Text(ImportText.title(forSource: id, label: label))
                    .font(ZimamType.body)
                let subtitle = ImportText.subtitle(forSource: id)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .frame(minHeight: ZimamSpacing.space11)
    }
}

private struct HistoryRow: View {
    let job: ImportJob
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            HStack(spacing: ZimamSpacing.space2) {
                Text(ImportText.title(forSource: job.source, label: job.source))
                    .font(ZimamType.body)
                Spacer(minLength: ZimamSpacing.space2)
                ImportStatusLabel(status: job.status)
                    .font(ZimamType.caption)
            }
            if let fileName = job.fileName {
                Text(fileName)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .lineLimit(1)
            }
            Text(date)
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            Text(job.isFinished ? ImportText.summary(job, locale: ZimamLocale.current)
                                : ImportText.progress(job, locale: ZimamLocale.current))
                .font(ZimamType.caption)
                .foregroundStyle(job.status == .failed ? ZimamColor.priorityHigh : ZimamColor.inkMuted)
                .lineLimit(2)
        }
        .padding(.vertical, ZimamSpacing.space1)
        .frame(minHeight: ZimamSpacing.space11)
        .accessibilityElement(children: .combine)
    }
}
