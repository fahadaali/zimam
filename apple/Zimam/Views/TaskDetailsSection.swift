import SwiftData
import SwiftUI
import ZimamKit

// MARK: Priority and project

struct TaskDetailsSection: View {
    let task: TaskItem
    let projects: [ProjectItem]
    let store: Store

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
}
