import SwiftData
import SwiftUI
import ZimamKit

/// The task whose «نقل إلى مشروع…» sheet is open.
struct ProjectMoveRequest: Identifiable {
    let id: UUID
}

/// «نقل إلى مشروع…»: the inbox, then each project with its sections. Choosing one moves the
/// task there at once (with its subtasks), as dropping it on the sidebar does on the iPad and
/// the Mac. It is also how VoiceOver and the iPhone move a task between projects.
struct MoveToProjectSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query private var matches: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete && $0.kindRaw == "project" }, sort: [SortDescriptor(\ProjectItem.sortOrder)])
    private var projects: [ProjectItem]
    @Query(filter: #Predicate<SectionItem> { !$0.pendingDelete },
           sort: [SortDescriptor(\SectionItem.sortOrder), SortDescriptor(\SectionItem.createdAt)])
    private var sections: [SectionItem]

    init(taskId: UUID) {
        _matches = Query(filter: #Predicate<TaskItem> { $0.id == taskId })
    }

    var body: some View {
        let sectionsByProject = Dictionary(grouping: sections, by: \.projectId)
        NavigationStack {
            Group {
                if let task = matches.first, !task.pendingDelete {
                    List {
                        Section {
                            destination("صندوق المهام", systemImage: "tray", project: nil, section: nil, task: task)
                        } header: {
                            Text(task.title)
                                .font(ZimamType.callout)
                                .foregroundStyle(ZimamColor.inkMuted)
                                .textCase(nil)
                        }
                        Section("المشاريع") {
                            if projects.isEmpty {
                                Text("لا مشاريع بعد.")
                                    .font(ZimamType.callout)
                                    .foregroundStyle(ZimamColor.inkMuted)
                            }
                            ForEach(projects) { project in
                                destination(project.name, systemImage: "folder", project: project.id, section: nil, task: task)
                                ForEach(sectionsByProject[project.id] ?? []) { section in
                                    destination(section.name, systemImage: "rectangle.split.3x1",
                                                project: project.id, section: section.id, task: task)
                                        .padding(.leading, ZimamSpacing.space6)
                                        .accessibilityLabel("\(section.name)، في \(project.name)")
                                }
                            }
                        }
                    }
                } else {
                    Text("لم تعد هذه المهمة موجودة.")
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("نقل إلى مشروع…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space11 * 9, minHeight: ZimamSpacing.space11 * 10)
        #endif
    }

    /// One place to move to; the task's current place is ticked and does nothing.
    private func destination(_ name: String, systemImage: String, project: UUID?, section: UUID?, task: TaskItem) -> some View {
        let isCurrent = task.projectId == project && task.sectionId == section
        return Button {
            guard !isCurrent else { return }
            withAnimation(.zimam(reduceMotion: reduceMotion)) {
                Store(context: context, sync: sync).move(task, toProject: project, section: section)
            }
            let message: String = "نُقلت إلى \(name)"
            AccessibilityNotification.Announcement(message).post()
            dismiss()
        } label: {
            HStack(spacing: ZimamSpacing.space2) {
                Label(name, systemImage: systemImage)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ZimamColor.brand)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: ZimamSpacing.space11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(ZimamColor.surfaceRaised)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(isCurrent ? "المهمة هنا الآن." : "")
    }
}
