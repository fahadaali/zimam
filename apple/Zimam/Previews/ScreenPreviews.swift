#if DEBUG
import SwiftUI

// The iPhone screens on the sample day (PreviewData), each in light and dark. Choose an iPhone
// simulator as the run destination to see the tabs. Tapping a task opens its details as in the
// app; edits stay in the in-memory store of PreviewEnvironment.

// MARK: The app

#Preview("التطبيق") {
    MainView()
        .zimamPreview()
}

#Preview("التطبيق، داكن") {
    MainView()
        .zimamPreview(.dark)
}

// MARK: Tabs

#Preview("اليوم") {
    NavigationStack { TodayView().taskDetailDestination() }
        .zimamPreview()
}

#Preview("اليوم، داكن") {
    NavigationStack { TodayView().taskDetailDestination() }
        .zimamPreview(.dark)
}

#Preview("القادم") {
    NavigationStack { UpcomingView().taskDetailDestination() }
        .zimamPreview()
}

#Preview("القادم، داكن") {
    NavigationStack { UpcomingView().taskDetailDestination() }
        .zimamPreview(.dark)
}

#Preview("التقويم") {
    NavigationStack { CalendarView().taskDetailDestination() }
        .zimamPreview()
}

#Preview("التقويم، داكن") {
    NavigationStack { CalendarView().taskDetailDestination() }
        .zimamPreview(.dark)
}

#Preview("المشاريع") {
    NavigationStack { ProjectsView().taskDetailDestination() }
        .zimamPreview()
}

#Preview("المشاريع، داكن") {
    NavigationStack { ProjectsView().taskDetailDestination() }
        .zimamPreview(.dark)
}

#Preview("البحث") {
    NavigationStack { SearchView().taskDetailDestination() }
        .zimamPreview()
}

#Preview("البحث، داكن") {
    NavigationStack { SearchView().taskDetailDestination() }
        .zimamPreview(.dark)
}

// MARK: A project

#Preview("مشروع: قائمة") {
    NavigationStack { ProjectDetailView(projectId: PreviewData.homeProjectId).taskDetailDestination() }
        .zimamPreview()
}

#Preview("مشروع: قائمة، داكن") {
    NavigationStack { ProjectDetailView(projectId: PreviewData.homeProjectId).taskDetailDestination() }
        .zimamPreview(.dark)
}

#Preview("مشروع: لوحة") {
    NavigationStack { ProjectDetailView(projectId: PreviewData.workProjectId).taskDetailDestination() }
        .zimamPreview()
}

#Preview("مشروع: لوحة، داكن") {
    NavigationStack { ProjectDetailView(projectId: PreviewData.workProjectId).taskDetailDestination() }
        .zimamPreview(.dark)
}

// MARK: A task

#Preview("تفاصيل المهمة") {
    NavigationStack { TaskDetailView(taskId: PreviewData.reportTaskId).taskDetailDestination() }
        .zimamPreview()
}

#Preview("تفاصيل المهمة، داكن") {
    NavigationStack { TaskDetailView(taskId: PreviewData.reportTaskId).taskDetailDestination() }
        .zimamPreview(.dark)
}

#Preview("مهمة جديدة") {
    AddTaskView(due: .today)
        .zimamPreview()
}

#Preview("مهمة جديدة، داكن") {
    AddTaskView(due: .today)
        .zimamPreview(.dark)
}

// MARK: Settings
// «تسجيل الخروج» and «حذف الحساب» here call the real server (PreviewEnvironment): look, don't tap.

#Preview("الإعدادات") {
    SettingsView()
        .zimamPreview()
}

#Preview("الإعدادات، داكن") {
    SettingsView()
        .zimamPreview(.dark)
}
#endif
