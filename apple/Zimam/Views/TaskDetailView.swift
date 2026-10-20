import SwiftData
import SwiftUI
import ZimamKit

/// A task's details: every field, its subtasks and its reminders. Pushed from any
/// task row (the same pushed screen on iPhone, iPad and Mac). Every edit goes
/// through `Store`, so it is saved, marked for sync and reflected in notifications.
struct TaskDetailView: View {
    let taskId: UUID

    /// This task and its subtasks only, and its reminders only: an edit to any other task does
    /// not re-fetch and re-render the form.
    @Query private var tasks: [TaskItem]
    @Query private var reminders: [ReminderItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }, sort: \ProjectItem.sortOrder)
    private var allProjects: [ProjectItem]

    init(taskId: UUID) {
        self.taskId = taskId
        let parent: UUID? = taskId
        _tasks = Query(filter: #Predicate<TaskItem> { !$0.pendingDelete && ($0.id == taskId || $0.parentId == parent) },
                       sort: \TaskItem.createdAt)
        _reminders = Query(filter: #Predicate<ReminderItem> { !$0.pendingDelete && $0.taskId == taskId },
                           sort: \ReminderItem.createdAt)
    }

    var body: some View {
        if let task = tasks.first(where: { $0.id == taskId }) {
            TaskDetailForm(
                task: task,
                subtasks: tasks.filter { $0.parentId == taskId },
                reminders: reminders.filter { $0.taskId == taskId },
                projects: allProjects.filter { $0.kindRaw == "project" }
            )
        } else {
            Text("لم تعد هذه المهمة موجودة.")
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.inkMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ZimamColor.surface)
        }
    }
}

private struct TaskDetailForm: View {
    let task: TaskItem
    let subtasks: [TaskItem]
    let reminders: [ReminderItem]
    let projects: [ProjectItem]

    enum Field: Hashable { case title, notes, tags }

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var loaded = false
    @State private var confirmingDelete = false
    @FocusState private var focused: Field?

    private var store: Store { Store(context: context, sync: sync) }

    var body: some View {
        Form {
            Section {
                TextField("عنوان المهمة", text: $title)
                    .font(ZimamType.headline)
                    .focused($focused, equals: .title)
                    .onSubmit(saveText)
                TextField("ملاحظات", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused, equals: .notes)
                TextField("الوسوم، مفصولة بفاصلة", text: $tags)
                    .focused($focused, equals: .tags)
                    .onSubmit(saveText)
            }

            #if os(iOS)
            // «المهمة الجارية»: a Live Activity with a timer (FocusSection.swift).
            FocusSection(task: task, projectName: projects.first { $0.id == task.projectId }?.name)
            #endif
            DueSection(task: task, store: store)
            DetailsSection(task: task, projects: projects, store: store)
            RecurrenceSection(task: task, store: store)
            SubtasksSection(task: task, subtasks: subtasks, store: store)
            RemindersSection(task: task, reminders: reminders, store: store)
            // Files live on the server and download when opened (TaskAttachmentsSection.swift).
            TaskAttachmentsSection(task: task)
            // Comments are for the members of a shared project; they live on the server.
            if let projectId = task.projectId {
                TaskCommentsSection(task: task, projectId: projectId)
            }

            Section {
                Button("حذف المهمة", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    .frame(minHeight: ZimamSpacing.space11)
                    // On the button, so on the iPad the dialog points at what asked for it.
                    .confirmationDialog("حذف المهمة؟", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("حذف", role: .destructive) {
                            store.delete(task)
                            dismiss()
                        }
                        Button("إلغاء", role: .cancel) {}
                    } message: {
                        Text("تُحذف معها مهامها الفرعية وتذكيراتها.")
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle("تفاصيل المهمة")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: load)
        .onDisappear(perform: saveText)
        .onChange(of: focused) { _, _ in saveText() }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        title = task.title
        notes = task.notes ?? ""
        tags = task.tags.joined(separator: "، ")
    }

    /// Saves the title, notes and tags when a field loses focus, on return, and on leaving.
    private func saveText() {
        guard loaded, !task.pendingDelete else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmedTitle.isEmpty ? task.title : trimmedTitle
        let newNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes
        let newTags = Self.parseTags(tags)
        if trimmedTitle.isEmpty { title = task.title }
        guard newTitle != task.title || newNotes != task.notes || newTags != task.tags else { return }
        store.update(task) { item in
            item.title = newTitle
            item.notes = newNotes
            item.tags = newTags
        }
    }

    /// Splits on the Latin or the Arabic comma, dropping blanks and repeats.
    static func parseTags(_ text: String) -> [String] {
        var result: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == "،" }) {
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty && !result.contains(tag) { result.append(tag) }
        }
        return result
    }
}

// MARK: Due date and prayer

private struct DueSection: View {
    let task: TaskItem
    let store: Store

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(SessionStore.self) private var session
    @Environment(LocationProvider.self) private var location

    var body: some View {
        let dueDate = task.dueDate.flatMap { formatter.date(fromDay: $0) }
        Section("الموعد") {
            Toggle("تاريخ الاستحقاق", isOn: hasDate)
            if let dueDate {
                DatePicker("التاريخ", selection: dateBinding(dueDate), in: dueRange, displayedComponents: .date)
                Text(formatter.dual(dueDate, withYear: true))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                StartDateRows(task: task, store: store)
            }
            Toggle("مرتبطة بوقت صلاة", isOn: hasPrayer)
            if let prayer = task.duePrayer {
                Picker("الصلاة", selection: prayerBinding) {
                    ForEach(Prayer.allCases, id: \.self) { Text($0.arabicName).tag($0) }
                }
                Stepper(value: offsetBinding, in: -120...120, step: 5) {
                    PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: task.duePrayerOffset, locale: formatter.locale))
                }
                if let time = prayerTime(prayer, on: dueDate ?? Date()) {
                    Text("الوقت المحسوب: \(formatter.time(time))")
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.sand)
                } else if location.coordinate == nil {
                    Text("حدّد موقعك لحساب وقت الصلاة.")
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                    LocationRequestRows()
                }
            }
        }
    }

    private func prayerTime(_ prayer: Prayer, on day: Date) -> Date? {
        guard let schedule = location.schedule(session.user?.settings) else { return nil }
        return schedule.time(of: prayer, on: day.addingTimeInterval(12 * 3600), offsetMinutes: task.duePrayerOffset ?? 0)
    }

    /// Clearing the due day clears the start day with it (`Store.setDueDate`).
    private var hasDate: Binding<Bool> {
        Binding(
            get: { task.dueDate != nil },
            set: { on in
                let today = formatter.dayString(from: Date())
                store.setDueDate(task, on ? today : nil)
            }
        )
    }

    private func dateBinding(_ current: Date) -> Binding<Date> {
        Binding(
            get: { current },
            set: { picked in store.setDueDate(task, formatter.dayString(from: picked)) }
        )
    }

    /// A task that spans days is due after its start day.
    private var dueRange: PartialRangeFrom<Date> {
        let earliest = task.startDate.flatMap { DayMath.adding(1, to: $0) }.flatMap { formatter.date(fromDay: $0) }
        return (earliest ?? .distantPast)...
    }

    private var hasPrayer: Binding<Bool> {
        Binding(
            get: { task.duePrayer != nil },
            set: { on in
                store.update(task) { item in
                    item.duePrayer = on ? Prayer.asr : nil
                    item.duePrayerOffset = on ? 0 : nil
                }
            }
        )
    }

    private var prayerBinding: Binding<Prayer> {
        Binding(
            get: { task.duePrayer ?? Prayer.asr },
            set: { prayer in store.update(task) { item in item.duePrayer = prayer } }
        )
    }

    private var offsetBinding: Binding<Int> {
        Binding(
            get: { task.duePrayerOffset ?? 0 },
            set: { offset in store.update(task) { item in item.duePrayerOffset = offset } }
        )
    }
}

/// «تاريخ البداية»: a task that spans days, from its start day to its due day. The start can only
/// be before the due day (the picker stops the day before it), as the server requires.
private struct StartDateRows: View {
    let task: TaskItem
    let store: Store

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Toggle("تاريخ البداية", isOn: hasStart)
        if let start = task.startDate.flatMap({ formatter.date(fromDay: $0) }), let latest {
            DatePicker("البداية", selection: startBinding(start), in: ...latest, displayedComponents: .date)
            Text(formatter.dual(start, withYear: true))
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            if let span = task.span {
                Text("تمتد المهمة \(ArabicCount.days(span.dayCount, locale: formatter.locale)).")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
    }

    /// The day before the due day: the latest start of a task that spans days.
    private var latest: Date? {
        task.dueDate.flatMap { DayMath.adding(-1, to: $0) }.flatMap { formatter.date(fromDay: $0) }
    }

    /// On, the task starts the day before it is due; the user then picks the day.
    private var hasStart: Binding<Bool> {
        Binding(
            get: { task.startDate != nil },
            set: { on in
                _ = store.setStartDate(task, on ? task.dueDate.flatMap { DayMath.adding(-1, to: $0) } : nil)
            }
        )
    }

    private func startBinding(_ current: Date) -> Binding<Date> {
        Binding(
            get: { current },
            set: { picked in _ = store.setStartDate(task, formatter.dayString(from: picked)) }
        )
    }
}

// MARK: Priority and project

private struct DetailsSection: View {
    let task: TaskItem
    let projects: [ProjectItem]
    let store: Store

    var body: some View {
        Section {
            Picker("الأولوية", selection: priorityBinding) {
                Text("بلا أولوية").tag(TaskPriority.none)
                Text("منخفضة").tag(TaskPriority.low)
                Text("متوسطة").tag(TaskPriority.medium)
                Text("عالية").tag(TaskPriority.high)
            }
            // A subtask belongs to its parent's project.
            if task.parentId == nil && !projects.isEmpty {
                Picker("المشروع", selection: projectBinding) {
                    Text("صندوق المهام").tag(UUID?.none)
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            // Tasks in a project can be assigned to one of its members.
            if let projectId = task.projectId {
                AssigneePicker(task: task, projectId: projectId, store: store)
            }
        }
    }

    private var priorityBinding: Binding<TaskPriority> {
        Binding(
            get: { task.priority },
            set: { priority in store.update(task) { item in item.priority = priority } }
        )
    }

    private var projectBinding: Binding<UUID?> {
        Binding(
            get: { task.projectId },
            set: { projectId in store.move(task, toProject: projectId) }
        )
    }
}

// MARK: Recurrence

private struct RecurrenceSection: View {
    let task: TaskItem
    let store: Store

    enum Choice: Hashable { case off, daily, weekly, monthly, yearly, custom }

    @Environment(\.dateFormatterZimam) private var formatter

    private var rule: Recurrence? {
        guard let text = task.recurrence else { return nil }
        return Recurrence(rrule: text)
    }

    private var choice: Choice {
        guard let text = task.recurrence, !text.isEmpty else { return .off }
        guard let parsed = Recurrence(rrule: text) else { return .custom }
        switch parsed.frequency {
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }

    var body: some View {
        let current = rule
        Section("التكرار") {
            Picker("التكرار", selection: choiceBinding) {
                Text("بلا تكرار").tag(Choice.off)
                Text("يومياً").tag(Choice.daily)
                Text("أسبوعياً").tag(Choice.weekly)
                Text("شهرياً").tag(Choice.monthly)
                Text("سنوياً").tag(Choice.yearly)
                if choice == .custom {
                    Text("تكرار مخصص").tag(Choice.custom)
                }
            }
            if let current, current.frequency == .weekly {
                WeekdayPicker(selected: current.weekdays) { day in toggle(day) }
            }
            if let current {
                Text(current.arabicDescription(locale: formatter.locale))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
    }

    private var choiceBinding: Binding<Choice> {
        Binding(get: { choice }, set: { newChoice in choose(newChoice) })
    }

    private func choose(_ newChoice: Choice) {
        let frequency: Recurrence.Frequency
        switch newChoice {
        case .off:
            store.update(task) { item in item.recurrence = nil }
            return
        case .custom:
            return
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        let current = rule
        var interval = 1
        var weekdays: [Weekday] = []
        if let current, current.frequency == frequency {
            interval = current.interval
            weekdays = current.weekdays
        }
        if frequency == .weekly && weekdays.isEmpty {
            weekdays = [defaultWeekday]
        }
        let updated = Recurrence(frequency: frequency, interval: interval, weekdays: weekdays,
                                 count: current?.count, until: current?.until)
        store.update(task) { item in item.recurrence = updated.rrule }
    }

    /// The weekday of the due date, or of today.
    private var defaultWeekday: Weekday {
        let day = task.dueDate.flatMap { formatter.date(fromDay: $0) } ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        return Weekday(rawValue: calendar.component(.weekday, from: day)) ?? .sunday
    }

    /// Adds or removes a weekday; the last one cannot be removed.
    private func toggle(_ day: Weekday) {
        guard var updated = rule else { return }
        if let index = updated.weekdays.firstIndex(of: day) {
            guard updated.weekdays.count > 1 else { return }
            updated.weekdays.remove(at: index)
        } else {
            updated.weekdays.append(day)
            updated.weekdays.sort { $0.rawValue < $1.rawValue }
        }
        let text = updated.rrule
        store.update(task) { item in item.recurrence = text }
    }
}

private struct WeekdayPicker: View {
    let selected: [Weekday]
    let onToggle: (Weekday) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: ZimamSpacing.space11 * 2), spacing: ZimamSpacing.space2)],
                  spacing: ZimamSpacing.space2) {
            ForEach(Weekday.allCases, id: \.self) { day in
                WeekdayButton(day: day, isOn: selected.contains(day)) { onToggle(day) }
            }
        }
        .padding(.vertical, ZimamSpacing.space1)
    }
}

private struct WeekdayButton: View {
    let day: Weekday
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(day.arabicName)
                .font(ZimamType.caption)
                .foregroundStyle(isOn ? ZimamColor.brandInk : ZimamColor.ink)
                .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
                .background(isOn ? ZimamColor.brandSoft : ZimamColor.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
                .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
                    .stroke(isOn ? ZimamColor.brand : ZimamColor.lineStrong))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: Subtasks

private struct SubtasksSection: View {
    let task: TaskItem
    let subtasks: [TaskItem]
    let store: Store

    @State private var newTitle = ""

    private var trimmed: String { newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section("المهام الفرعية") {
            ForEach(subtasks) { subtask in
                SubtaskRow(task: subtask, store: store)
            }
            HStack(spacing: ZimamSpacing.space2) {
                TextField("مهمة فرعية جديدة", text: $newTitle)
                    .onSubmit(add)
                Button("إضافة", action: add)
                    .buttonStyle(.zimamQuiet)
                    .disabled(trimmed.isEmpty)
            }
            // The assistant proposes steps; nothing is added before «إضافة».
            SubtaskBreakdown(task: task, store: store)
        }
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        store.addSubtask(to: task, title: trimmed)
        newTitle = ""
    }
}

private struct SubtaskRow: View {
    let task: TaskItem
    let store: Store

    var body: some View {
        NavigationLink(value: TaskRoute(id: task.id)) {
            HStack(spacing: ZimamSpacing.space2) {
                CompletionCircle(isDone: task.isDone, font: ZimamType.headline) {
                    withAnimation(.zimamComplete) { store.toggleDone(task) }
                }

                Text(task.title)
                    .font(ZimamType.body)
                    .foregroundStyle(task.isDone ? ZimamColor.inkFaint : ZimamColor.ink)
                    .strikethrough(task.isDone)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: Reminders

private struct RemindersSection: View {
    let task: TaskItem
    let reminders: [ReminderItem]
    let store: Store

    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location
    @Environment(\.dateFormatterZimam) private var formatter

    @State private var time = Date().addingTimeInterval(3600)
    @State private var prayer: Prayer = .asr
    @State private var offset = 0
    @State private var addingPlace = false

    private var hasPlaces: Bool {
        reminders.contains { $0.kindRaw == ReminderRecord.Kind.location.rawValue }
    }

    var body: some View {
        Section {
            ForEach(reminders) { reminder in
                ReminderRow(reminder: reminder) { store.deleteReminder(reminder) }
            }

            DatePicker("وقت التذكير", selection: $time, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            Text(formatter.dual(time, withYear: true))
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            Button("إضافة تذكير بالوقت", systemImage: "bell") {
                store.addTimeReminder(to: task.id, at: time)
                askForAlerts()
            }
            .frame(minHeight: ZimamSpacing.space11)

            Picker("الصلاة", selection: $prayer) {
                ForEach(Prayer.allCases, id: \.self) { Text($0.arabicName).tag($0) }
            }
            Stepper(value: $offset, in: -120...120, step: 5) {
                PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: offset, locale: formatter.locale))
            }
            Button("إضافة تذكير بالصلاة", systemImage: "moon.stars") {
                store.addPrayerReminder(to: task.id, prayer: prayer, offsetMinutes: offset)
                askForAlerts()
            }
            .frame(minHeight: ZimamSpacing.space11)

            Button("إضافة تذكير بالموقع", systemImage: "mappin.and.ellipse") { addingPlace = true }
                .frame(minHeight: ZimamSpacing.space11)
                .sheet(isPresented: $addingPlace) {
                    LocationReminderSheet { place, time in
                        store.addLocationReminder(to: task.id, place: place, at: time)
                        #if os(iOS)
                        // Location while using the app lets the system watch the place; the sheet
                        // offered «دائماً» with its reason.
                        location.requestAuthorization()
                        #endif
                        askForAlerts()
                    }
                }
            #if os(iOS)
            if hasPlaces && !location.canWatchPlaces && !location.isUndecided,
               let url = LocationProvider.systemSettingsURL {
                Link(destination: url) {
                    Label(location.isDenied ? "السماح بالموقع لتذكيرات الموقع" : "تفعيل الموقع الدقيق لتذكيرات الموقع",
                          systemImage: "gear")
                }
                .frame(minHeight: ZimamSpacing.space11)
            }
            #endif
        } header: {
            Text("التذكيرات")
        } footer: {
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                if notifications.isDenied {
                    Text("الإشعارات متوقفة لزمام. فعّلها من إعدادات النظام لتصلك التذكيرات.")
                } else if location.coordinate == nil {
                    Text("تذكيرات الصلاة تحتاج موقعك. حدّده من الإعدادات.")
                } else if task.dueDate == nil {
                    Text("تذكير الصلاة لمهمة بلا تاريخ يتكرر كل يوم.")
                }
                if hasPlaces {
                    #if os(iOS)
                    Text("تذكير المكان وحده يصلك كلما وصلت أو غادرت حتى تنجز المهمة، والمرتبط بوقت يصلك مرة عند أيهما أسبق.")
                    #else
                    Text("تذكيرات الموقع تصل على الآيفون والآيباد، ولا تعمل على الماك.")
                    #endif
                }
            }
        }
        // A reminder added from a sheet that has just closed.
        .sensoryFeedback(.success, trigger: reminders.count) { old, new in new > old }
    }

    private func askForAlerts() {
        Task { await notifications.requestFullAuthorization() }
    }
}

private struct ReminderRow: View {
    let reminder: ReminderItem
    let onDelete: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(ZimamColor.inkMuted)
                    .frame(minWidth: ZimamSpacing.space11, minHeight: ZimamSpacing.space11)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("حذف التذكير")
        }
    }

    @ViewBuilder private var content: some View {
        switch ReminderRecord.Kind(rawValue: reminder.kindRaw) ?? .time {
        case .prayer:
            if let prayer = reminder.prayerRaw.flatMap({ Prayer(rawValue: $0) }) {
                PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: reminder.offsetMinutes, locale: formatter.locale))
            }
        case .time:
            if let at = reminder.at, let date = ReminderPlanner.date(fromISO: at) {
                let text = "\(formatter.label(for: date))، \(formatter.time(date))"
                Label(text, systemImage: "bell")
                    .font(ZimamType.callout)
                    .foregroundStyle(date < Date() ? ZimamColor.inkFaint : ZimamColor.ink)
            }
        case .location:
            let place = reminder.record.location
            let firing = reminder.firing()
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Label(place.map { LocationReminderPlanner.reminderText($0, firing: firing, formatter: formatter) }
                          ?? LocationReminderPlanner.displayName(nil),
                      systemImage: place?.trigger == .leave ? "figure.walk.departure" : "figure.walk.arrival")
                    .font(ZimamType.callout)
                    .foregroundStyle(placeNote == nil && firing.watchesPlace ? ZimamColor.ink : ZimamColor.inkMuted)
                if let place {
                    Text("النطاق \(LocationReminderPlanner.radiusText(place.radius, locale: formatter.locale))")
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                if let placeNote {
                    Text(placeNote)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
        }
    }

    /// Why a location reminder is not watched on this device, or nil when it is (or when
    /// notifications themselves are off, which the section's footer already says).
    private var placeNote: String? {
        let firing = reminder.firing()
        // Fired already: the row says so, and nothing is watched any more.
        guard firing.watchesPlace else { return nil }
        #if os(iOS)
        if !notifications.isEnabled { return nil }
        if notifications.watchedPlaces.contains(reminder.id) {
            if case .waiting = firing, location.needsAlways {
                return "قد يصلك التذكيران معاً. اسمح بالموقع «دائماً» ليصلك أيهما أسبق فقط."
            }
            return nil
        }
        if !location.canWatchPlaces {
            return location.isUndecided || location.isDenied
                ? "لا يعمل حتى تسمح لزمام بالموقع."
                : "لا يعمل حتى تفعّل «الموقع الدقيق» لزمام."
        }
        let limit = location.canMonitorPlaces ? PlaceWatchPlanner.maxPlaces : LocationReminderPlanner.maxRegions
        guard notifications.watchedPlaces.count >= limit else { return nil }
        let count = limit.formatted(.number.locale(formatter.locale))
        return "لا يعمل الآن: يراقب زمام \(count) \(limit > 10 ? "مكاناً" : "أماكن") على الأكثر، أقربها موعداً."
        #else
        if case .waiting = firing {
            return "يصلك هنا في الوقت فقط؛ المكان على الآيفون والآيباد."
        }
        return "لا يعمل على الماك، ويصلك على الآيفون والآيباد."
        #endif
    }
}
