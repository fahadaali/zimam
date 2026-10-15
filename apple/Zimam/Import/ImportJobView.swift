import SwiftUI
import ZimamKit

/// One import: progress while it runs (polling `GET /v1/imports/:id`), then what it did.
/// Polling stops when the view goes away (`.task` is cancelled with it); the job carries on
/// on the server and shows in the history.
struct ImportJobView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dateFormatterZimam) private var formatter

    @State private var job: ImportJob
    @State private var pollError: String?

    init(job: ImportJob) {
        _job = State(initialValue: job)
    }

    var body: some View {
        Form {
            Section {
                ImportStatusLabel(status: job.status)
                    .font(ZimamType.headline)
                if job.isFinished {
                    Text(ImportText.summary(job, locale: ZimamLocale.current))
                        .font(ZimamType.body)
                } else {
                    if let fraction = ImportText.fraction(job) {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(ImportText.progress(job, locale: ZimamLocale.current))
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .monospacedDigit()
                }
                if let fileName = job.fileName {
                    LabeledContent("الملف", value: fileName)
                }
                LabeledContent("البدء", value: startedText)
            } header: {
                Text(ImportText.title(forSource: job.source, label: job.source))
            } footer: {
                if let pollError {
                    Text(pollError).foregroundStyle(ZimamColor.priorityHigh)
                } else if !job.isFinished {
                    Text("يمكنك مغادرة هذه الشاشة؛ يكمل الاستيراد في الخادم، وتصلك المهام بالمزامنة.")
                }
            }

            if job.status != .queued {
                Section {
                    ForEach(ImportText.countRows(job.counts)) { row in
                        LabeledContent(row.label, value: row.value.formatted(.number.locale(ZimamLocale.current)))
                    }
                } header: {
                    Text("الأعداد")
                } footer: {
                    if job.counts.skipped > 0 {
                        Text("«بقي كما عُدِّل في زمام»: عناصر عدّلتها أو حذفتها في زمام بعد آخر استيراد، فلم يُكتب فوقها.")
                    }
                }
            }

            if !job.warnings.isEmpty {
                Section("ملاحظات") {
                    ForEach(job.warnings, id: \.self) { warning in
                        Text(warning).font(ZimamType.callout)
                    }
                }
            }

            if !job.errors.isEmpty {
                Section("ما تعذّر استيراده") {
                    ForEach(job.errors, id: \.self) { item in
                        Label(item.message, systemImage: "exclamationmark.triangle")
                            .font(ZimamType.callout)
                            .foregroundStyle(ZimamColor.priorityHigh)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle(job.isFinished ? "نتيجة الاستيراد" : "جارٍ الاستيراد")
        .task(id: job.id) { await follow() }
    }

    private var startedText: String {
        let date = Date(timeIntervalSince1970: TimeInterval(job.createdAt) / 1000)
        return "\(formatter.label(for: date))، \(formatter.time(date))"
    }

    /// Polls until the job ends, then syncs so the new tasks show at once (realtime nudges too).
    private func follow() async {
        guard !job.isFinished else { return }
        var failures = 0
        while !job.isFinished {
            let delay = job.status == .queued ? 2.0 : 1.5
            try? await Task.sleep(for: .seconds(min(30, delay * pow(2, Double(failures)))))
            if Task.isCancelled { return }
            do {
                job = try await session.api.importJob(id: job.id)
                pollError = nil
                failures = 0
            } catch {
                if Task.isCancelled { return }
                if (error as? APIError)?.isUnauthorized == true {
                    pollError = "انتهت الجلسة. سجّل الدخول مرة أخرى."
                    return
                }
                failures = min(failures + 1, 4)
                pollError = "تعذّر تحديث الحالة، وستُعاد المحاولة."
            }
        }
        AccessibilityNotification.Announcement(ImportText.summary(job, locale: ZimamLocale.current)).post()
        await sync.sync()
    }
}

/// The status with its icon; colour never carries the meaning alone.
struct ImportStatusLabel: View {
    let status: ImportJob.Status

    var body: some View {
        Label(ImportText.status(status), systemImage: icon)
            .foregroundStyle(color)
    }

    private var icon: String {
        switch status {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch status {
        case .queued, .running: ZimamColor.inkMuted
        case .done: ZimamColor.success
        case .failed: ZimamColor.priorityHigh
        }
    }
}
