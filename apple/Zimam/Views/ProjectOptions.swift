import SwiftData
import SwiftUI
import ZimamKit

// «خيارات المشروع»: «إعادة التسمية»، «أرشفة المشروع» (or «استرجاع المشروع»)، and, after a divider,
// «حذف المشروع». The same items sit in a project's context menu (ProjectsView, SidebarView) and in
// the «…» menu of its screen (ProjectDetailView). Owners and editors rename and archive; the owner
// alone deletes, after a question that names what goes with the project (ProjectPermissions).
// The web app has the same menu (web/public/app/project-menu.js).

/// What a «خيارات المشروع» menu asked for next: the rename alert or the delete question.
enum ProjectAction: Identifiable, Equatable {
    case rename(UUID)
    case delete(UUID)

    var id: String {
        switch self {
        case .rename(let id): "rename-\(id)"
        case .delete(let id): "delete-\(id)"
        }
    }

    var projectId: UUID {
        switch self {
        case .rename(let id), .delete(let id): id
        }
    }
}

/// The signed-in user's permissions on a project, from its members once loaded.
@MainActor
func projectPermissions(_ project: ProjectItem, me: UUID?) -> ProjectPermissions {
    let memberRole = ProjectMembers.shared.members(of: project.id)?.first { $0.userId == me }?.role
    return ProjectPermissions(role: ProjectPermissions.role(ownerId: project.ownerId, me: me, memberRole: memberRole))
}

/// The menu's items, for a `Menu` or a `.contextMenu`. Archiving happens at once (it is undone with
/// «استرجاع المشروع»); renaming and deleting go through `action`, which `.projectActions` answers.
struct ProjectOptionsItems: View {
    let project: ProjectItem
    @Binding var action: ProjectAction?
    /// After archiving: the screen of the project can close, as it has left the lists.
    var onArchived: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(SessionStore.self) private var session

    var body: some View {
        let can = projectPermissions(project, me: session.user?.id)
        let archived = project.archivedAt != nil
        if can.canRename {
            Button("إعادة التسمية", systemImage: "pencil") { action = .rename(project.id) }
        }
        if can.canArchive {
            Button(ProjectActionText.archiveLabel(archived: archived), systemImage: archived ? "arrow.uturn.backward" : "archivebox") {
                Store(context: context, sync: sync).setArchived(project, !archived)
                if !archived { onArchived?() }
            }
        }
        if can.canDelete {
            Divider()
            Button("حذف المشروع", systemImage: "trash", role: .destructive) { action = .delete(project.id) }
        }
    }
}

/// Answers a `ProjectAction`: the rename alert with the name filled in, and the delete question
/// with «إلغاء» as the safe answer.
private struct ProjectActionsModifier: ViewModifier {
    @Binding var action: ProjectAction?
    var onDeleted: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]
    @State private var newName = ""

    private var project: ProjectItem? {
        guard let action else { return nil }
        return projects.first { $0.id == action.projectId }
    }

    private func presenting(_ match: @escaping (ProjectAction) -> Bool) -> Binding<Bool> {
        Binding(
            get: { action.map(match) ?? false },
            set: { if !$0 { action = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: action) { _, now in
                if case .rename = now { newName = project?.name ?? "" }
            }
            .alert("إعادة تسمية المشروع", isPresented: presenting { if case .rename = $0 { true } else { false } }) {
                TextField("اسم المشروع", text: $newName)
                Button("إلغاء", role: .cancel) {}
                Button("حفظ") {
                    if let project { Store(context: context, sync: sync).rename(project, to: newName) }
                }
            }
            .confirmationDialog(
                ProjectActionText.deleteQuestion(project?.name ?? ""),
                isPresented: presenting { if case .delete = $0 { true } else { false } },
                titleVisibility: .visible
            ) {
                Button("حذف المشروع", role: .destructive) {
                    guard let project else { return }
                    Store(context: context, sync: sync).delete(project)
                    onDeleted?()
                }
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text(ProjectActionText.deleteNote)
            }
    }
}

extension View {
    /// Shows what a «خيارات المشروع» menu asked for. `onDeleted` closes a screen of the deleted project.
    func projectActions(_ action: Binding<ProjectAction?>, onDeleted: (() -> Void)? = nil) -> some View {
        modifier(ProjectActionsModifier(action: action, onDeleted: onDeleted))
    }
}

/// «المشاريع المؤرشفة»: a folded section under the projects, each with «استرجاع» and its menu.
struct ArchivedProjectsSection: View {
    let projects: [ProjectItem]
    @Binding var action: ProjectAction?
    @State private var expanded = false

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(SessionStore.self) private var session

    var body: some View {
        if !projects.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(projects) { project in
                        HStack(spacing: ZimamSpacing.space2) {
                            Text(project.name)
                                .font(ZimamType.body)
                                .foregroundStyle(ZimamColor.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if projectPermissions(project, me: session.user?.id).canArchive {
                                Button(ProjectActionText.archiveLabel(archived: true), systemImage: "arrow.uturn.backward") {
                                    Store(context: context, sync: sync).setArchived(project, false)
                                }
                                .labelStyle(.titleOnly)
                                .buttonStyle(.bordered)
                            }
                        }
                        .frame(minHeight: ZimamSpacing.space11)
                        .contextMenu { ProjectOptionsItems(project: project, action: $action) }
                    }
                } label: {
                    Text(ProjectActionText.archivedTitle)
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .badge(projects.count)
                }
            }
        }
    }
}
