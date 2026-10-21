import SwiftData
import SwiftUI
import ZimamKit

// The sections of «مهمة جديدة» (AddTaskView.swift). The add screen owns the state; each section
// gets only the values and bindings it shows.

// MARK: Title

/// The title, «إملاء», «اقتراح بالمساعد», and the notes and tags a suggestion filled in.
struct AddTaskTitleSection: View {
    @Binding var title: String
    @Binding var notes: String
    @Binding var tagsText: String
    var titleFocused: FocusState<Bool>.Binding
    /// Filled when a suggestion is edited into the form: notes and tags are shown.
    let fromAssistant: Bool
    let dictation: SpeechDictation
    let assistantIsLoading: Bool
    let onSubmit: () -> Void
    let onToggleDictation: () -> Void
    let onSuggest: () -> Void

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section {
            TextField(hint: "عنوان المهمة", text: $title)
                .labelsHidden()
                .focused(titleFocused)
                .onSubmit(onSubmit)
            AddTaskDictationControl(dictation: dictation, assistantIsLoading: assistantIsLoading, onToggle: onToggleDictation)
            if NetworkMonitor.shared.isOnline {
                Button("اقتراح بالمساعد", systemImage: "text.badge.checkmark", action: onSuggest)
                    .buttonStyle(.zimamQuiet)
                    .disabled(trimmedTitle.isEmpty || assistantIsLoading)
            }
            if fromAssistant {
                TextField(hint: "ملاحظات", text: $notes, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...4)
                TextField(hint: "الوسوم، مفصولة بفاصلة", text: $tagsText)
                    .labelsHidden()
            }
        } footer: {
            Text(NetworkMonitor.shared.isOnline
                 ? "اكتب المهمة كما تقولها، مثل «ذكرني أراجع العقد بعد المغرب يوم الخميس»، ثم اطلب اقتراح المساعد."
                 : "المساعد يحتاج اتصالاً بالإنترنت، والإضافة اليدوية تعمل دونه.")
        }
    }
}

// MARK: Dictation

/// «إملاء» and, while listening, the words heard so far go into the title field.
struct AddTaskDictationControl: View {
    let dictation: SpeechDictation
    let assistantIsLoading: Bool
    let onToggle: () -> Void

    var body: some View {
        let listening = dictation.phase == .listening
        Button(listening ? "إيقاف الإملاء" : "إملاء",
               systemImage: listening ? "stop.circle" : "mic",
               action: onToggle)
            .buttonStyle(.zimamQuiet)
            .disabled(dictation.phase == .starting || assistantIsLoading)
            .accessibilityHint(listening ? "يوقف الاستماع ويقرأ المساعد المهمة." : "قل المهمة بصوتك، مثل «ذكرني أراجع العقد بعد العصر بكرة».")
        switch dictation.phase {
        case .listening:
            Label("أستمع… قل المهمة كما تقولها لشخص.", systemImage: "waveform")
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.inkMuted)
                .frame(minHeight: ZimamSpacing.space11, alignment: .leading)
                .accessibilityElement(children: .combine)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.inkMuted)
                .frame(minHeight: ZimamSpacing.space11, alignment: .leading)
        case .idle, .starting:
            EmptyView()
        }
    }
}

// MARK: Assistant

/// The assistant's answer: reading, failed (the sentence can still go in as it is), or a
/// suggestion to accept, edit into the form, or dismiss.
struct AddTaskAssistantSection: View {
    let phase: AddTaskView.AssistantPhase
    /// The last failure was `pro_required`: the status offers the paywall.
    let needsPro: Bool
    let canAddAsIs: Bool
    let projects: [ProjectItem]
    let onRetry: () -> Void
    let onClose: () -> Void
    let onAddAsIs: () -> Void
    let onAccept: (TaskSuggestion) -> Void
    let onEdit: (TaskSuggestion) -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .loading:
            Section { AssistantStatus(phase: .loading("يقرأ المساعد المهمة…")) }
        case .failed(let message):
            Section {
                AssistantStatus(phase: .failed(message), needsPro: needsPro, onRetry: onRetry, onClose: onClose)
                // The assistant never blocks adding: the sentence can go in as it is.
                if canAddAsIs {
                    Button("إضافة بالنص كما هو", systemImage: "plus.circle", action: onAddAsIs)
                        .buttonStyle(.zimamQuiet)
                }
            }
        case .suggestion(let suggestion):
            Section {
                TaskSuggestionCard(
                    suggestion: suggestion,
                    projectName: suggestion.projectId.flatMap { id in projects.first(where: { $0.id == id })?.name },
                    onAccept: { onAccept(suggestion) },
                    onEdit: { onEdit(suggestion) },
                    onDismiss: onDismiss
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }
}

// MARK: Due

/// «الموعد» and «تاريخ البداية»; the time in the day follows in `TaskTimeRows`.
struct AddTaskDueSection: View {
    @Environment(\.dateFormatterZimam) private var formatter

    @Binding var due: AddTaskView.Due
    @Binding var pickedDate: Date
    @Binding var hasStart: Bool
    @Binding var startDate: Date
    /// The day before the due day, nil when unscheduled.
    let latestStart: Date?

    var body: some View {
        Section {
            Picker("الموعد", selection: $due) {
                Text("بلا موعد").tag(AddTaskView.Due.unscheduled)
                Text("اليوم").tag(AddTaskView.Due.today)
                Text("غداً").tag(AddTaskView.Due.tomorrow)
                Text("تاريخ آخر").tag(AddTaskView.Due.pickedDate)
            }
            if due == .pickedDate {
                DatePicker("التاريخ", selection: $pickedDate, displayedComponents: .date)
                Text(formatter.dual(pickedDate, withYear: true))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            if due != .unscheduled, let latestStart {
                Toggle("تاريخ البداية", isOn: $hasStart)
                if hasStart {
                    DatePicker("البداية", selection: $startDate, in: ...latestStart, displayedComponents: .date)
                    Text(formatter.dual(startDate, withYear: true))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
        }
    }
}

// MARK: Priority and project

struct AddTaskPrioritySection: View {
    @Binding var priority: TaskPriority
    @Binding var projectId: UUID?
    let projects: [ProjectItem]

    var body: some View {
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
}
