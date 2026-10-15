import SwiftData
import SwiftUI
import ZimamKit

/// Adds a task: title, when it is due, an optional prayer anchor, priority and project.
/// «اقتراح بالمساعد» reads the typed sentence on the server and shows the result for review;
/// nothing is added until the user accepts it or edits it into the form.
struct AddTaskView: View {
    enum Due: Hashable { case unscheduled, today, tomorrow, pickedDate }

    enum AssistantPhase: Equatable {
        case idle
        case loading
        case failed(String)
        case suggestion(TaskSuggestion)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(SessionStore.self) private var session
    @Environment(\.dateFormatterZimam) private var formatter
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete && $0.kindRaw == "project" }, sort: [SortDescriptor(\ProjectItem.sortOrder)])
    private var projects: [ProjectItem]

    @State private var title = ""
    @State private var due: Due
    @State private var pickedDate = Date()
    @State private var linkPrayer = false
    @State private var prayer: Prayer = .asr
    @State private var offset = 0
    @State private var priority: TaskPriority = .none
    @State private var projectId: UUID?
    @State private var assistant: AssistantPhase = .idle
    /// Filled when a suggestion is edited into the form: shown and kept on add.
    @State private var fromAssistant = false
    @State private var notes = ""
    @State private var tagsText = ""
    @State private var dueTime: String?
    @FocusState private var titleFocused: Bool

    init(due: Due = .unscheduled, projectId: UUID? = nil) {
        _due = State(initialValue: due)
        _projectId = State(initialValue: projectId)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("عنوان المهمة", text: $title)
                        .focused($titleFocused)
                        .onSubmit(add)
                    if NetworkMonitor.shared.isOnline {
                        Button("اقتراح بالمساعد", systemImage: "text.badge.checkmark", action: suggest)
                            .buttonStyle(.zimamQuiet)
                            .disabled(trimmedTitle.isEmpty || assistant == .loading)
                    }
                    if fromAssistant {
                        TextField("ملاحظات", text: $notes, axis: .vertical)
                            .lineLimit(1...4)
                        TextField("الوسوم، مفصولة بفاصلة", text: $tagsText)
                    }
                } footer: {
                    Text(NetworkMonitor.shared.isOnline
                         ? "اكتب المهمة كما تقولها، مثل «ذكرني أراجع العقد بعد المغرب يوم الخميس»، ثم اطلب اقتراح المساعد."
                         : "المساعد يحتاج اتصالاً بالإنترنت، والإضافة اليدوية تعمل دونه.")
                }

                assistantSection

                Section {
                    Picker("الموعد", selection: $due) {
                        Text("بلا موعد").tag(Due.unscheduled)
                        Text("اليوم").tag(Due.today)
                        Text("غداً").tag(Due.tomorrow)
                        Text("تاريخ آخر").tag(Due.pickedDate)
                    }
                    if due == .pickedDate {
                        DatePicker("التاريخ", selection: $pickedDate, displayedComponents: .date)
                        Text(formatter.dual(pickedDate, withYear: true))
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                    if let dueTime, due != .unscheduled, !linkPrayer,
                       let time = clockTime(dueTime, formatter: formatter) {
                        HStack(spacing: ZimamSpacing.space2) {
                            Text("الوقت: \(time)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("إزالة") { self.dueTime = nil }
                                .buttonStyle(.zimamQuiet)
                        }
                    }
                }

                Section {
                    Toggle("مرتبطة بوقت صلاة", isOn: $linkPrayer)
                    if linkPrayer {
                        Picker("الصلاة", selection: $prayer) {
                            ForEach(Prayer.allCases, id: \.self) { Text($0.arabicName).tag($0) }
                        }
                        Stepper(value: $offset, in: -120...120, step: 5) {
                            PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: offset, locale: formatter.locale))
                        }
                    }
                }

                Section {
                    Picker("الأولوية", selection: $priority) {
                        Text("بلا أولوية").tag(TaskPriority.none)
                        Text("منخفضة").tag(TaskPriority.low)
                        Text("متوسطة").tag(TaskPriority.medium)
                        Text("عالية").tag(TaskPriority.high)
                    }
                    if !projects.isEmpty {
                        Picker("المشروع", selection: $projectId) {
                            Text("صندوق المهام").tag(UUID?.none)
                            ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
            }
            .navigationTitle("مهمة جديدة")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إضافة", action: add).disabled(trimmedTitle.isEmpty)
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    // MARK: Assistant

    @ViewBuilder private var assistantSection: some View {
        switch assistant {
        case .idle:
            EmptyView()
        case .loading:
            Section { AssistantStatus(phase: .loading("يقرأ المساعد المهمة…")) }
        case .failed(let message):
            Section {
                AssistantStatus(phase: .failed(message), onRetry: suggest, onClose: { assistant = .idle })
            }
        case .suggestion(let suggestion):
            Section {
                TaskSuggestionCard(
                    suggestion: suggestion,
                    projectName: suggestion.projectId.flatMap { id in projects.first(where: { $0.id == id })?.name },
                    onAccept: { accept(suggestion) },
                    onEdit: { edit(suggestion) },
                    onDismiss: { withAnimation { assistant = .idle } }
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private func suggest() {
        let text = trimmedTitle
        guard !text.isEmpty else { return }
        titleFocused = false
        assistant = .loading
        Task {
            do {
                let suggestion = try await session.api.suggestTask(from: text, timeZone: formatter.timeZone)
                withAnimation { assistant = .suggestion(suggestion) }
            } catch {
                assistant = .failed(AssistantProblem(error).message(formatter: formatter))
            }
        }
    }

    /// Adds the suggestion as it is. A project not on this device yet is left out.
    private func accept(_ suggestion: TaskSuggestion) {
        let knownProject = suggestion.projectId.flatMap { id in projects.contains(where: { $0.id == id }) ? id : nil }
        Store(context: context, sync: sync).addTask(
            title: suggestion.title,
            projectId: knownProject ?? projectId,
            dueDate: suggestion.dueDate,
            duePrayer: suggestion.duePrayer,
            duePrayerOffset: suggestion.duePrayerOffset ?? 0,
            priority: suggestion.priority,
            notes: suggestion.notes,
            dueTime: suggestion.dueTime,
            tags: suggestion.tags
        )
        dismiss()
    }

    /// Puts the suggestion in the form to change before adding.
    private func edit(_ suggestion: TaskSuggestion) {
        title = suggestion.title
        notes = suggestion.notes ?? ""
        tagsText = suggestion.tags.joined(separator: "، ")
        dueTime = suggestion.dueTime
        fromAssistant = true
        if let day = suggestion.dueDate, let date = formatter.date(fromDay: day) {
            let today = formatter.dayString(from: Date())
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()).map { formatter.dayString(from: $0) }
            if day == today {
                due = .today
            } else if day == tomorrow {
                due = .tomorrow
            } else {
                due = .pickedDate
                pickedDate = date
            }
        } else {
            due = .unscheduled
        }
        if let prayer = suggestion.duePrayer {
            linkPrayer = true
            self.prayer = prayer
            // The stepper goes from two hours before to two hours after, in steps of five.
            let offset = min(max(suggestion.duePrayerOffset ?? 0, -120), 120)
            self.offset = offset - offset % 5
        } else {
            linkPrayer = false
        }
        priority = suggestion.priority
        if let id = suggestion.projectId, projects.contains(where: { $0.id == id }) {
            projectId = id
        }
        withAnimation { assistant = .idle }
    }

    /// Splits on the Latin or the Arabic comma, dropping blanks and repeats.
    private var parsedTags: [String] {
        var result: [String] = []
        for part in tagsText.split(whereSeparator: { $0 == "," || $0 == "،" }) {
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty && !result.contains(tag) { result.append(tag) }
        }
        return result
    }

    private func add() {
        guard !trimmedTitle.isEmpty else { return }
        let day: Date? = switch due {
        case .unscheduled: nil
        case .today: Date()
        case .tomorrow: Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case .pickedDate: pickedDate
        }
        Store(context: context, sync: sync).addTask(
            title: trimmedTitle,
            projectId: projectId,
            dueDate: day.map { formatter.dayString(from: $0) },
            duePrayer: linkPrayer ? prayer : nil,
            duePrayerOffset: linkPrayer ? offset : nil,
            priority: priority,
            notes: fromAssistant ? notes : nil,
            dueTime: fromAssistant ? dueTime : nil,
            tags: fromAssistant ? parsedTags : []
        )
        dismiss()
    }
}
