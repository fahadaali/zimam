import SwiftData
import SwiftUI
import ZimamKit

/// Adds a task: title, when it is due, an optional prayer anchor, priority and project.
/// «اقتراح بالمساعد» reads the typed sentence on the server and shows the result for review;
/// nothing is added until the user accepts it or edits it into the form. «إملاء» fills the title
/// from speech (SpeechDictation), then asks the assistant the same way; offline, or when the
/// assistant cannot help, the dictated words stay in the title to add as they are.
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
    @Environment(LocationProvider.self) private var location
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete && $0.kindRaw == "project" }, sort: [SortDescriptor(\ProjectItem.sortOrder)])
    private var projects: [ProjectItem]

    @State private var title = ""
    @State private var due: Due
    @State private var pickedDate = Date()
    /// «تاريخ البداية»: the task spans days, from this day to its due day.
    @State private var hasStart = false
    @State private var startDate = Date()
    @State private var linkPrayer = false
    @State private var prayer: Prayer = .asr
    @State private var offset = 0
    @State private var priority: TaskPriority = .none
    @State private var projectId: UUID?
    @State private var assistant: AssistantPhase = .idle
    /// The last failure was `pro_required`: the status offers the paywall.
    @State private var assistantNeedsPro = false
    /// Filled when a suggestion is edited into the form: shown and kept on add.
    @State private var fromAssistant = false
    @State private var notes = ""
    @State private var tagsText = ""
    @State private var dueTime: String?
    /// The assistant's place («إذا وصلت البيت»), added as a reminder with the task.
    @State private var suggestedPlace: TaskSuggestion.PlaceSuggestion?
    @State private var dictation = SpeechDictation()
    /// What was typed before dictation started; the dictated words follow it.
    @State private var dictationPrefix = ""
    @FocusState private var titleFocused: Bool

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Splits on the Latin or the Arabic comma, dropping blanks and repeats.
    private var parsedTags: [String] {
        var result: [String] = []
        for part in tagsText.split(whereSeparator: { $0 == "," || $0 == "،" }) {
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty && !result.contains(tag) { result.append(tag) }
        }
        return result
    }

    /// The chosen due day, nil when unscheduled.
    private var dueDay: Date? {
        switch due {
        case .unscheduled: nil
        case .today: Date()
        case .tomorrow: Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case .pickedDate: pickedDate
        }
    }

    /// The latest start day: the day before the due day (the start of that day, in the user's zone).
    private var latestStart: Date? {
        dueDay.flatMap { DayMath.adding(-1, to: formatter.dayString(from: $0)) }.flatMap { formatter.date(fromDay: $0) }
    }

    /// `date` is the day `.pickedDate` starts on (the calendar passes its selected day).
    init(due: Due = .unscheduled, projectId: UUID? = nil, date: Date = Date()) {
        _due = State(initialValue: due)
        _projectId = State(initialValue: projectId)
        _pickedDate = State(initialValue: date)
    }

    var body: some View {
        NavigationStack {
            Form {
                AddTaskTitleSection(
                    title: $title,
                    notes: $notes,
                    tagsText: $tagsText,
                    titleFocused: $titleFocused,
                    fromAssistant: fromAssistant,
                    dictation: dictation,
                    assistantIsLoading: assistant == .loading,
                    onSubmit: add,
                    onToggleDictation: toggleDictation,
                    onSuggest: suggest
                )

                AddTaskAssistantSection(
                    phase: assistant,
                    needsPro: assistantNeedsPro,
                    canAddAsIs: !trimmedTitle.isEmpty,
                    projects: projects,
                    onRetry: suggest,
                    onClose: closeAssistant,
                    onAddAsIs: add,
                    onAccept: accept,
                    onEdit: edit,
                    onDismiss: dismissSuggestion
                )

                AddTaskDueSection(
                    due: $due,
                    pickedDate: $pickedDate,
                    hasStart: $hasStart,
                    startDate: $startDate,
                    dueTime: $dueTime,
                    latestStart: latestStart,
                    linkPrayer: linkPrayer
                )

                AddTaskPrayerSection(linkPrayer: $linkPrayer, prayer: $prayer, offset: $offset)

                AddTaskPrioritySection(priority: $priority, projectId: $projectId, projects: projects)
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
            // A new start begins the day before the due day; a due day moved before it pulls it back.
            .onChange(of: hasStart) { _, on in startToggled(on) }
            .onChange(of: latestStart) { _, latest in latestStartChanged(latest) }
            .onDisappear(perform: stopDictation)
            .onChange(of: dictation.transcript) { _, words in transcriptChanged(words) }
        }
    }

    // MARK: Form

    private func startToggled(_ on: Bool) {
        if on, let latestStart { startDate = latestStart }
    }

    private func latestStartChanged(_ latest: Date?) {
        if let latest, startDate > latest { startDate = latest }
    }

    // MARK: Dictation

    private func stopDictation() {
        dictation.cancel()
        // The closure holds this view, whose state holds the dictation: let go on close.
        dictation.onFinish = nil
    }

    private func transcriptChanged(_ words: String) {
        if dictation.isActive { title = dictationPrefix + words }
    }

    private func toggleDictation() {
        if dictation.phase != .listening {
            titleFocused = false
            let typed = trimmedTitle
            dictationPrefix = typed.isEmpty ? "" : typed + " "
            withAnimation(.zimam(reduceMotion: reduceMotion)) { assistant = .idle }
            dictation.onFinish = { _ in dictationFinished() }
        }
        dictation.toggle()
    }

    /// The dictated sentence goes to the assistant when it can be reached; otherwise it stays
    /// in the title, ready to add as it is.
    private func dictationFinished() {
        guard !trimmedTitle.isEmpty, NetworkMonitor.shared.isOnline else { return }
        suggest()
    }

    // MARK: Assistant

    private func closeAssistant() {
        assistant = .idle
    }

    private func dismissSuggestion() {
        withAnimation(.zimam(reduceMotion: reduceMotion)) { assistant = .idle }
    }

    private func suggest() {
        let text = trimmedTitle
        guard !text.isEmpty else { return }
        titleFocused = false
        assistant = .loading
        Task {
            do {
                let suggestion = try await session.api.suggestTask(from: text, timeZone: formatter.timeZone)
                withAnimation(.zimam(reduceMotion: reduceMotion)) { assistant = .suggestion(suggestion) }
            } catch {
                let problem = AssistantProblem(error)
                assistantNeedsPro = problem == .proRequired
                assistant = .failed(problem.message(formatter: formatter))
            }
        }
    }

    /// Adds the suggestion as it is. A project not on this device yet is left out.
    private func accept(_ suggestion: TaskSuggestion) {
        let knownProject = suggestion.projectId.flatMap { id in projects.contains(where: { $0.id == id }) ? id : nil }
        let task = Store(context: context, sync: sync).addTask(
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
        if let place = suggestion.place {
            let at = SpokenTask(suggestion: suggestion)
                .placeReminderAt(today: formatter.dayString(from: Date()), timeZone: formatter.timeZone)
                .flatMap(ReminderPlanner.date(fromISO:))
            addSuggestedPlace(place, to: task, at: at)
        }
        dismiss()
    }

    /// The sentence's saved place as a reminder on the new task; a place not on this device
    /// (not saved, or not pulled yet) is left out, as the card said.
    private func addSuggestedPlace(_ suggested: TaskSuggestion.PlaceSuggestion, to task: TaskItem, at: Date?) {
        guard let id = suggested.placeId else { return }
        var descriptor = FetchDescriptor<PlaceItem>(predicate: #Predicate { $0.id == id && !$0.pendingDelete })
        descriptor.fetchLimit = 1
        guard let place = try? context.fetch(descriptor).first else { return }
        let copy = ReminderRecord.Location(place: place.record, trigger: suggested.trigger)
        Store(context: context, sync: sync).addLocationReminder(to: task.id, place: copy, at: at)
        #if os(iOS)
        location.requestAuthorization()
        #endif
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
        suggestedPlace = suggestion.place
        withAnimation(.zimam(reduceMotion: reduceMotion)) { assistant = .idle }
    }

    // MARK: Adding

    private func add() {
        guard !trimmedTitle.isEmpty else { return }
        let day = dueDay
        let task = Store(context: context, sync: sync).addTask(
            title: trimmedTitle,
            projectId: projectId,
            dueDate: day.map { formatter.dayString(from: $0) },
            duePrayer: linkPrayer ? prayer : nil,
            duePrayerOffset: linkPrayer ? offset : nil,
            priority: priority,
            notes: fromAssistant ? notes : nil,
            dueTime: fromAssistant ? dueTime : nil,
            tags: fromAssistant ? parsedTags : [],
            startDate: hasStart && day != nil ? formatter.dayString(from: startDate) : nil
        )
        if fromAssistant, let suggestedPlace {
            // The form's day and the assistant's time, when both are still set.
            let at = day.flatMap { day in
                dueTime.flatMap { clockDate($0, on: day) }
            }
            addSuggestedPlace(suggestedPlace, to: task, at: at)
        }
        dismiss()
    }

    /// "17:00" on `day`, in the user's zone.
    private func clockDate(_ hhmm: String, on day: Date) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day).flatMap { $0 > Date() ? $0 : nil }
    }
}
