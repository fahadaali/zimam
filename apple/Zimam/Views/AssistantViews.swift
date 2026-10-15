import SwiftData
import SwiftUI
import ZimamKit

// The in-app assistant on three screens: a task from a sentence (AddTaskView), steps for a
// task (TaskDetailView) and the day's summary (TodayView). Each request goes through the
// server (api/src/routes/assistant.ts), saves nothing, and needs the network; offline the
// entry points hide, and a failure shows one Arabic sentence without blocking the screen.

// MARK: Task from a sentence

/// The suggestion read from the typed sentence, as the user reviews it before adding.
struct TaskSuggestionCard: View {
    let suggestion: TaskSuggestion
    let projectName: String?
    let onAccept: () -> Void
    let onEdit: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        AssistantSuggestion(acceptLabel: "إضافة", dismissLabel: "تجاهل", secondaryLabel: "تعديل",
                            onAccept: onAccept, onSecondary: onEdit, onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                Text("قرأت المهمة هكذا:")
                    .foregroundStyle(ZimamColor.inkMuted)
                Text(suggestion.title)
                    .font(ZimamType.headline)
                    .foregroundStyle(ZimamColor.ink)
                if let notes = suggestion.notes, !notes.isEmpty {
                    Text(notes)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                if let when = whenText {
                    SuggestionLine(name: "الموعد", value: when)
                }
                if let prayer = suggestion.duePrayer {
                    PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: suggestion.duePrayerOffset, locale: formatter.locale))
                }
                if suggestion.priority != TaskPriority.none {
                    HStack(spacing: ZimamSpacing.space2) {
                        SuggestionLine(name: "الأولوية", value: suggestion.priority.arabicName)
                        PriorityFlag(priority: suggestion.priority)
                    }
                }
                if let projectName {
                    SuggestionLine(name: "المشروع", value: projectName)
                }
                if !suggestion.tags.isEmpty {
                    SuggestionLine(name: "الوسوم", value: suggestion.tags.joined(separator: "، "))
                }
            }
        }
    }

    /// «الخميس، ٤ جمادى الأولى، ١٥ أكتوبر، ٩:٣٠ م»: the near word, both calendars, then the time.
    private var whenText: String? {
        guard let day = suggestion.dueDate, let date = formatter.date(fromDay: day) else { return nil }
        var parts: [String] = []
        if let word = formatter.relativeWord(for: date) { parts.append(word) }
        parts.append(formatter.dual(date))
        if let time = suggestion.dueTime.flatMap({ clockTime($0, on: date, formatter: formatter) }) {
            parts.append(time)
        }
        return parts.joined(separator: "، ")
    }
}

/// «الأولوية: عالية».
private struct SuggestionLine: View {
    let name: String
    let value: String

    var body: some View {
        Text("\(name): \(value)")
            .foregroundStyle(ZimamColor.ink)
    }
}

/// "21:30" on `day` in the user's clock format: «٩:٣٠ م».
func clockTime(_ hhmm: String, on day: Date = Date(), formatter: DualDateFormatter) -> String? {
    let parts = hhmm.split(separator: ":").compactMap { Int($0) }
    guard parts.count >= 2 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = formatter.timeZone
    guard let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day) else { return nil }
    return formatter.time(date)
}

// MARK: Steps for a task

/// «تقسيم إلى خطوات» under a task's subtasks: the assistant proposes three to eight steps,
/// the user unticks any they do not want, and «إضافة» adds the rest as subtasks.
struct SubtaskBreakdown: View {
    let task: TaskItem
    let store: Store

    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
        case ready([String])
    }

    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dateFormatterZimam) private var formatter
    @State private var phase: Phase = .idle
    @State private var selected: Set<Int> = []

    var body: some View {
        switch phase {
        case .idle:
            if NetworkMonitor.shared.isOnline {
                Button("تقسيم إلى خطوات", systemImage: "list.bullet.indent", action: start)
                    .buttonStyle(.zimamQuiet)
            }
        case .loading:
            AssistantStatus(phase: .loading("يقسّم المساعد المهمة…"))
        case .failed(let message):
            AssistantStatus(phase: .failed(message), onRetry: start, onClose: { phase = .idle })
        case .ready(let titles):
            AssistantSuggestion(acceptLabel: "إضافة", onAccept: { accept(titles) }, onDismiss: { phase = .idle }) {
                VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                    Text("قسّمت المهمة إلى \(Self.steps(titles.count, locale: formatter.locale)). أزل ما لا تريده، ثم أضف الباقي مهامَّ فرعية.")
                    ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                        StepToggle(title: title, isOn: selected.contains(index)) {
                            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    private func start() {
        phase = .loading
        Task {
            // The server breaks down the task it has; send a new task or a fresh title first.
            if task.isDirty { await sync.sync() }
            do {
                let titles = try await session.api.suggestSubtasks(for: task.id)
                selected = Set(titles.indices)
                phase = titles.isEmpty ? .failed("لم يقترح المساعد خطوات لهذه المهمة.") : .ready(titles)
            } catch {
                phase = .failed(AssistantProblem(error).message(formatter: formatter))
            }
        }
    }

    private func accept(_ titles: [String]) {
        for (offset, index) in selected.sorted().enumerated() where titles.indices.contains(index) {
            // Distinct creation times keep the steps in the assistant's order.
            if let subtask = store.addSubtask(to: task, title: titles[index]) {
                subtask.createdAt += Int64(offset)
            }
        }
        withAnimation { phase = .idle }
    }

    /// «٣ خطوات», «١١ خطوة»; after «إلى», so two is «خطوتين».
    static func steps(_ count: Int, locale: Locale) -> String {
        let number = count.formatted(.number.locale(locale))
        switch count {
        case 1: return "خطوة واحدة"
        case 2: return "خطوتين"
        case 3...10: return "\(number) خطوات"
        default: return "\(number) خطوة"
        }
    }
}

/// One proposed step with its tick.
private struct StepToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZimamSpacing.space2) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? ZimamColor.brand : ZimamColor.lineStrong)
                Text(title)
                    .foregroundStyle(ZimamColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: ZimamSpacing.space11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: The day's summary

/// «ملخص اليوم» at the top of Today: the day's tasks, overdue ones and the next
/// prayer-tied task in a few sentences. An empty day is answered without the model.
struct DaySummaryRow: View {
    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
        case ready(DaySummary)
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.dateFormatterZimam) private var formatter
    @State private var phase: Phase = .idle

    var body: some View {
        Group {
            switch phase {
            case .idle:
                if NetworkMonitor.shared.isOnline {
                    Button("ملخص اليوم", systemImage: "text.alignright", action: load)
                        .buttonStyle(.zimamQuiet)
                }
            case .loading:
                AssistantStatus(phase: .loading("يجهّز المساعد ملخص اليوم…"))
            case .failed(let message):
                AssistantStatus(phase: .failed(message), onRetry: load, onClose: { phase = .idle })
            case .ready(let summary):
                AssistantSuggestion(label: "ملخص اليوم", dismissLabel: "إخفاء", onDismiss: { withAnimation { phase = .idle } }) {
                    Text(summary.text)
                        .lineSpacing(ZimamType.calloutLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func load() {
        phase = .loading
        let today = formatter.dayString(from: Date())
        Task {
            do {
                let summary = try await session.api.daySummary(day: today)
                phase = .ready(summary)
            } catch {
                phase = .failed(AssistantProblem(error).message(formatter: formatter))
            }
        }
    }
}
