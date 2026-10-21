#if DEBUG
import SwiftUI
import ZimamKit

// The SwiftUI equivalents of design/components/, each in light and dark: the task row, the date,
// time, prayer and place chips with the priority flag, the project card, the button, and the
// assistant's suggestion. The task rows are the sample day's (PreviewData).

// MARK: Task row

#Preview("سطر المهمة") {
    TaskRowSamples()
        .zimamPreview()
}

#Preview("سطر المهمة، داكن") {
    TaskRowSamples()
        .zimamPreview(.dark)
}

/// A task at a time with notes, one at a prayer, one in the inbox, one overdue, one done, and a
/// kanban card's compact title. The circle completes and reopens the task in the preview's store.
private struct TaskRowSamples: View {
    private struct Sample: Identifiable {
        let taskId: UUID
        let projectName: String?
        var compact = false

        /// The same task appears twice, full and compact.
        var id: String { "\(taskId.uuidString)-\(compact)" }
    }

    private var samples: [Sample] {
        [
            Sample(taskId: PreviewData.reportTaskId, projectName: "العمل"),
            Sample(taskId: PreviewData.wirdTaskId, projectName: "التعلّم"),
            Sample(taskId: PreviewData.callTaskId, projectName: nil),
            Sample(taskId: PreviewData.overdueTaskId, projectName: "البيت"),
            Sample(taskId: PreviewData.doneTaskId, projectName: "العمل"),
            Sample(taskId: PreviewData.reportTaskId, projectName: nil, compact: true),
        ]
    }

    var body: some View {
        let env = PreviewEnvironment.shared
        let store = Store(context: env.container.mainContext, sync: nil)
        ScrollView {
            VStack(spacing: ZimamSpacing.space2) {
                ForEach(samples) { sample in
                    if let task = env.task(sample.taskId) {
                        TaskRow(task: task, projectName: sample.projectName, compact: sample.compact) {
                            store.toggleDone(task)
                        }
                        .padding(.horizontal, ZimamSpacing.space4)
                        .padding(.vertical, ZimamSpacing.space2)
                        .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
                    }
                }
            }
            .padding(ZimamSpacing.space4)
        }
        .background(ZimamColor.surface)
    }
}

// MARK: Chips

#Preview("الشرائح") {
    ChipSamples()
        .zimamPreview()
}

#Preview("الشرائح، داكن") {
    ChipSamples()
        .zimamPreview(.dark)
}

/// The date chip (near, far and overdue), the time chip, the prayer chip with and without its
/// computed time, the place chip unselected and selected, and the three priority flags.
private struct ChipSamples: View {
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.prayerScheduleZimam) private var schedule

    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        let nextWeek = calendar.date(byAdding: .day, value: 9, to: now) ?? now
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now) ?? now
        let tenOClock = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        let asr = schedule?.times(on: now)[.asr]
        VStack(alignment: .leading, spacing: ZimamSpacing.space4) {
            HStack(spacing: ZimamSpacing.space2) {
                DateChip(text: formatter.label(for: now))
                DateChip(text: formatter.label(for: nextWeek))
                DateChip(text: formatter.label(for: twoDaysAgo), overdue: true)
            }
            HStack(spacing: ZimamSpacing.space2) {
                TimeChip(text: formatter.time(tenOClock))
                if let asr {
                    PrayerChip(text: formatter.time(asr), phrase: PrayerPhrase.text(.asr, offsetMinutes: -10, locale: formatter.locale))
                }
                PrayerChip(text: PrayerPhrase.text(.maghrib, offsetMinutes: nil, locale: formatter.locale))
            }
            HStack(spacing: ZimamSpacing.space2) {
                PlaceChip(name: "البيت")
                PlaceChip(name: "العمل", isSelected: true)
            }
            HStack(spacing: ZimamSpacing.space4) {
                PriorityFlag(priority: .high)
                PriorityFlag(priority: .medium)
                PriorityFlag(priority: .low)
            }
        }
        .padding(ZimamSpacing.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ZimamColor.surface)
    }
}

// MARK: Project card

#Preview("بطاقة المشروع") {
    ProjectCardSamples()
        .zimamPreview()
}

#Preview("بطاقة المشروع، داكن") {
    ProjectCardSamples()
        .zimamPreview(.dark)
}

/// In progress, the active one (the sidebar's selection), and an empty project.
private struct ProjectCardSamples: View {
    var body: some View {
        VStack(spacing: ZimamSpacing.space3) {
            ProjectCard(name: "العمل", done: 3, total: 8)
            ProjectCard(name: "البيت", done: 1, total: 5, active: true)
            ProjectCard(name: "التعلّم", done: 0, total: 0)
        }
        .padding(ZimamSpacing.space4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ZimamColor.surface)
    }
}

// MARK: Button

#Preview("الزر") {
    ButtonSamples()
        .zimamPreview()
}

#Preview("الزر، داكن") {
    ButtonSamples()
        .zimamPreview(.dark)
}

/// Primary (one per screen), secondary, quiet, and primary disabled.
private struct ButtonSamples: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space3) {
            Button("إضافة مهمة") {}
                .buttonStyle(.zimamPrimary)
            Button("تعديل") {}
                .buttonStyle(.zimamSecondary)
            Button("تجاهل") {}
                .buttonStyle(.zimamQuiet)
            Button("إضافة مهمة") {}
                .buttonStyle(.zimamPrimary)
                .disabled(true)
        }
        .padding(ZimamSpacing.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ZimamColor.surface)
    }
}

// MARK: Assistant suggestion

#Preview("اقتراح المساعد") {
    AssistantSamples()
        .zimamPreview()
}

#Preview("اقتراح المساعد، داكن") {
    AssistantSamples()
        .zimamPreview(.dark)
}

/// The suggestion card with its three actions, then the loading and failed states in its place.
private struct AssistantSamples: View {
    var body: some View {
        VStack(spacing: ZimamSpacing.space4) {
            AssistantSuggestion(acceptLabel: "إضافة", secondaryLabel: "تعديل",
                                onAccept: {}, onSecondary: {}, onDismiss: {}) {
                Text("أضفت «مراجعة تقرير الربع الثالث» غداً بعد العصر، بأولوية عالية.")
            }
            AssistantStatus(phase: .loading("يقرأ المساعد المهمة…"))
            AssistantStatus(phase: .failed("تعذّر الوصول إلى المساعد. أضف المهمة كما كتبتها."),
                            onRetry: {}, onClose: {})
        }
        .padding(ZimamSpacing.space4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ZimamColor.surface)
    }
}
#endif
