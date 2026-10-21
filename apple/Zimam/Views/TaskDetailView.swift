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
                // Archived projects leave the picker, except the one the task is in.
                projects: allProjects.filter { $0.kindRaw == "project" && ($0.archivedAt == nil || $0.id == task.projectId) }
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
    enum Field: Hashable { case title, notes, tags }

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss

    let task: TaskItem
    let subtasks: [TaskItem]
    let reminders: [ReminderItem]
    let projects: [ProjectItem]

    @State private var title = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var loaded = false
    @FocusState private var focused: Field?

    private var store: Store { Store(context: context, sync: sync) }

    var body: some View {
        Form {
            Section {
                TextField(hint: "عنوان المهمة", text: $title)
                    .labelsHidden()
                    .font(ZimamType.headline)
                    .focused($focused, equals: .title)
                    .onSubmit(saveText)
                TextField(hint: "ملاحظات", text: $notes, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(3...8)
                    .focused($focused, equals: .notes)
                TextField(hint: "الوسوم، مفصولة بفاصلة", text: $tags)
                    .labelsHidden()
                    .focused($focused, equals: .tags)
                    .onSubmit(saveText)
            }

            #if os(iOS)
            // «المهمة الجارية»: a Live Activity with a timer (FocusSection.swift).
            FocusSection(task: task, projectName: projects.first { $0.id == task.projectId }?.name)
            #endif
            // The time and the reminders that count from it, together.
            TaskDueSection(task: task, store: store)
            TaskRemindersSection(task: task, reminders: reminders, store: store)
            TaskDetailsSection(task: task, projects: projects, store: store)
            TaskRecurrenceSection(task: task, store: store)
            TaskSubtasksSection(task: task, subtasks: subtasks, store: store)
            // Files live on the server and download when opened (TaskAttachmentsSection.swift).
            TaskAttachmentsSection(task: task)
            // Comments are for the members of a shared project; they live on the server.
            if let projectId = task.projectId {
                TaskCommentsSection(task: task, projectId: projectId)
            }

            TaskDeleteSection(onDelete: deleteTask)
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

    private func deleteTask() {
        store.delete(task)
        dismiss()
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

/// «حذف المهمة», confirmed first.
private struct TaskDeleteSection: View {
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        Section {
            Button("حذف المهمة", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                .frame(minHeight: ZimamSpacing.space11)
                // On the button, so on the iPad the dialog points at what asked for it.
                .confirmationDialog("حذف المهمة؟", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("حذف", role: .destructive, action: onDelete)
                    Button("إلغاء", role: .cancel) {}
                } message: {
                    Text("تُحذف معها مهامها الفرعية وتذكيراتها.")
                }
        }
    }
}
