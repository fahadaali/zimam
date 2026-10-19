import SwiftData
import SwiftUI
import ZimamKit

// What members of a shared project see on a task: its comments and who it is assigned to.
// Comments live on the server (GET/POST /v1/tasks/:id/comments) and need the network;
// the assignee is a task field that syncs like any other edit.

// MARK: Comments

/// The task's comments, oldest first, with a field to add one. Loads when the task opens,
/// after each sync (another member may have commented), and when the connection returns.
struct TaskCommentsSection: View {
    let task: TaskItem
    let projectId: UUID

    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var comments: [TaskComment] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var deleting: TaskComment?
    /// Counts loads and the changes made here: a load that answers after a newer load, or after
    /// a change here, does not put an older list back.
    @State private var version = 0
    /// The reload asked for by a sync or by coming back online; replaced by the next, and
    /// cancelled when the section goes away.
    @State private var reloading: Task<Void, Never>?

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let online = NetworkMonitor.shared.isOnline
        let me = session.user?.id
        let members = ProjectMembers.shared.members(of: projectId) ?? []
        Section("التعليقات") {
            if online && !loaded && problem == nil {
                AssistantStatus(phase: .loading("تُحمَّل التعليقات…"))
            }
            if loaded && comments.isEmpty {
                Text("لا تعليقات بعد.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            ForEach(comments) { comment in
                CommentRow(
                    comment: comment,
                    author: authorName(of: comment, members: members, me: me),
                    isMine: comment.authorId != nil && comment.authorId == me,
                    onDelete: { deleting = comment }
                )
                // On the row that asked, so on the iPad the dialog points at it.
                .confirmationDialog("حذف التعليق؟", isPresented: deletingBinding(for: comment), titleVisibility: .visible) {
                    Button("حذف", role: .destructive) { delete(comment) }
                    Button("إلغاء", role: .cancel) {}
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            Group {
                if online {
                    HStack(alignment: .bottom, spacing: ZimamSpacing.space2) {
                        TextField("أضف تعليقاً", text: $draft, axis: .vertical)
                            .lineLimit(1...5)
                        Button("إرسال", action: send)
                            .buttonStyle(.zimamQuiet)
                            .disabled(trimmed.isEmpty || sending)
                    }
                } else {
                    Text("التعليقات تحتاج اتصالاً بالإنترنت.")
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
            .task(id: task.id) { await load() }
            .onChange(of: sync.lastSyncedAt) { _, _ in reload(quietly: true) }
            .onChange(of: online) { _, isOnline in
                if isOnline { reload(quietly: false) }
            }
            .onDisappear { reloading?.cancel() }
        }
    }

    private func authorName(of comment: TaskComment, members: [ProjectMember], me: UUID?) -> String {
        let name = comment.authorName ?? members.first(where: { $0.userId == comment.authorId })?.name
        return ProjectMembers.displayName(name, userId: comment.authorId, me: me)
    }

    private func deletingBinding(for comment: TaskComment) -> Binding<Bool> {
        Binding(get: { deleting?.id == comment.id }, set: { if !$0, deleting?.id == comment.id { deleting = nil } })
    }

    private func reload(quietly: Bool) {
        reloading?.cancel()
        reloading = Task { await load(quietly: quietly) }
    }

    private func load(quietly: Bool = false) async {
        guard NetworkMonitor.shared.isOnline else { return }
        version += 1
        let mine = version
        do {
            let fresh = try await session.api.comments(on: task.id)
            guard mine == version else { return }
            comments = fresh
            problem = nil
        } catch let error as APIError where error.status == 404 {
            guard mine == version else { return }
            // A new task that has not reached the server yet has no comments.
            comments = []
        } catch {
            guard mine == version, !Task.isCancelled else { return }
            if !quietly { problem = SharingProblem.message(for: error) }
        }
        loaded = true
        // Names for the authors and the assignee picker.
        if ProjectMembers.shared.members(of: projectId) == nil {
            _ = try? await ProjectMembers.shared.load(projectId, api: session.api)
        }
    }

    private func send() {
        let body = trimmed
        guard !body.isEmpty, !sending else { return }
        sending = true
        Task {
            // The server needs the task before it can hold its comments.
            if task.isDirty { await sync.sync() }
            do {
                let comment = try await session.api.addComment(body, to: task.id)
                version += 1
                withAnimation(reduceMotion ? nil : .default) { comments.append(comment) }
                draft = ""
                problem = nil
            } catch {
                problem = SharingProblem.message(for: error)
            }
            sending = false
        }
    }

    private func delete(_ comment: TaskComment) {
        deleting = nil
        Task {
            do {
                try await session.api.deleteComment(comment.id)
                version += 1
                withAnimation(reduceMotion ? nil : .default) { comments.removeAll { $0.id == comment.id } }
            } catch {
                problem = SharingProblem.message(for: error)
            }
        }
    }
}

private struct CommentRow: View {
    let comment: TaskComment
    let author: String
    let isMine: Bool
    let onDelete: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        let date = comment.createdDate
        HStack(alignment: .top, spacing: ZimamSpacing.space2) {
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Text(author)
                    .font(ZimamType.caption.weight(.semibold))
                    .foregroundStyle(ZimamColor.ink)
                Text(comment.body)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // Both calendars, then the time: «٢ جمادى الأولى، ١٣ أكتوبر، ٣:٠٠ م».
                Text("\(formatter.dual(date))، \(formatter.time(date))")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if isMine {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(ZimamColor.inkMuted)
                        .frame(minWidth: ZimamSpacing.space11, minHeight: ZimamSpacing.space11)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("حذف التعليق")
            }
        }
    }
}

// MARK: Assignee

/// «المسند إليه» for a task in a project, from the project's members. Shown once the
/// project has more than one member (or the task is already assigned). Viewers cannot change it.
struct AssigneePicker: View {
    let task: TaskItem
    let projectId: UUID
    let store: Store

    @Environment(SessionStore.self) private var session

    var body: some View {
        let me = session.user?.id
        if let members = ProjectMembers.shared.members(of: projectId), members.count > 1 || task.assigneeId != nil {
            let myRole = members.first { $0.userId == me }?.role
            Picker("المسند إليه", selection: binding) {
                Text("بلا إسناد").tag(UUID?.none)
                ForEach(members) { member in
                    Text(ProjectMembers.displayName(member.name, userId: member.userId, me: me))
                        .tag(Optional(member.userId))
                }
                // Someone who left the project keeps the tag until the server clears it.
                if let assignee = task.assigneeId, !members.contains(where: { $0.userId == assignee }) {
                    Text("عضو سابق").tag(Optional(assignee))
                }
            }
            .disabled(myRole == .viewer)
        } else if let assignee = task.assigneeId {
            LabeledContent("المسند إليه", value: assignee == me ? "أنت" : "عضو في المشروع")
        }
    }

    private var binding: Binding<UUID?> {
        Binding(
            get: { task.assigneeId },
            set: { assignee in store.update(task) { item in item.assigneeId = assignee } }
        )
    }
}
