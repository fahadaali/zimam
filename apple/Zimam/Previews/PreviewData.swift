#if DEBUG
import Foundation
import SwiftData
import ZimamKit

/// The sample day the previews show, dated from today so «اليوم» and «القادم» always have tasks:
/// three projects (العمل as a board), tasks due today at a time and at a prayer, one overdue and
/// one done, upcoming ones (one spanning days, two repeating), subtasks, reminders, saved places,
/// and two tasks in the inbox. Inserted as synced records, so nothing is waiting to be sent.
enum PreviewData {
    static let homeProjectId = UUID(uuidString: "5A0E2C10-7B1D-4E6A-9C3F-000000000001")!
    static let workProjectId = UUID(uuidString: "5A0E2C10-7B1D-4E6A-9C3F-000000000002")!
    static let learningProjectId = UUID(uuidString: "5A0E2C10-7B1D-4E6A-9C3F-000000000003")!

    /// «مراجعة تقرير الربع الثالث»: today at 10:00, high priority, with notes, a tag, two subtasks
    /// and a reminder. The task details preview opens it.
    static let reportTaskId = UUID(uuidString: "5A0E2C10-7B1D-4E6A-9C3F-000000000101")!
    /// Daily, after Fajr.
    static let wirdTaskId = UUID(uuidString: "5A0E2C10-7B1D-4E6A-9C3F-000000000102")!
    /// In the inbox, before Asr.
    static let callTaskId = UUID(uuidString: "5A0E2C10-7B1D-4E6A-9C3F-000000000103")!
    static let overdueTaskId = UUID(uuidString: "5A0E2C10-7B1D-4E6A-9C3F-000000000104")!
    static let doneTaskId = UUID(uuidString: "5A0E2C10-7B1D-4E6A-9C3F-000000000105")!

    static func seed(_ context: ModelContext, formatter: DualDateFormatter) {
        let today = formatter.dayString(from: Date())
        func day(_ offset: Int) -> String { DayMath.adding(offset, to: today) ?? today }

        let projects: [ProjectRecord] = [
            ProjectRecord(id: homeProjectId, name: "البيت", sortOrder: 0),
            ProjectRecord(id: workProjectId, name: "العمل", view: .kanban, sortOrder: 1),
            ProjectRecord(id: learningProjectId, name: "التعلّم", sortOrder: 2),
        ]
        for project in projects { context.insert(ProjectItem(project, dirty: false)) }

        let shopping = SectionRecord(projectId: homeProjectId, name: "المشتريات", sortOrder: 0)
        let upkeep = SectionRecord(projectId: homeProjectId, name: "الصيانة", sortOrder: 1)
        let backlog = SectionRecord(projectId: workProjectId, name: "قائمة الانتظار", sortOrder: 0)
        let doing = SectionRecord(projectId: workProjectId, name: "قيد التنفيذ", sortOrder: 1)
        let review = SectionRecord(projectId: workProjectId, name: "للمراجعة", sortOrder: 2)
        for section in [shopping, upkeep, backlog, doing, review] { context.insert(SectionItem(section, dirty: false)) }

        let tasks: [TaskRecord] = [
            TaskRecord(id: reportTaskId, projectId: workProjectId, sectionId: doing.id, title: "مراجعة تقرير الربع الثالث",
                       notes: "إرسال الملاحظات إلى فريق المالية قبل نهاية الدوام.", priority: .high, tags: ["تقارير"],
                       dueDate: day(0), dueTime: "10:00"),
            TaskRecord(projectId: workProjectId, sectionId: doing.id, parentId: reportTaskId, title: "التحقق من أرقام المبيعات",
                       status: .done, completedAt: Milliseconds.now),
            TaskRecord(projectId: workProjectId, sectionId: doing.id, parentId: reportTaskId, title: "تدقيق الرسوم البيانية"),
            TaskRecord(id: wirdTaskId, projectId: learningProjectId, title: "قراءة الورد اليومي", dueDate: day(0),
                       duePrayer: .fajr, duePrayerOffset: 15, recurrence: "FREQ=DAILY"),
            TaskRecord(id: callTaskId, title: "الاتصال بالوالدة", dueDate: day(0), duePrayer: .asr, duePrayerOffset: -10),
            TaskRecord(projectId: homeProjectId, sectionId: shopping.id, title: "شراء مستلزمات البيت", priority: .medium,
                       dueDate: day(0), duePrayer: .maghrib),
            TaskRecord(id: overdueTaskId, projectId: homeProjectId, sectionId: upkeep.id, title: "تجديد رخصة السيارة",
                       priority: .high, dueDate: day(-2)),
            TaskRecord(id: doneTaskId, projectId: workProjectId, sectionId: review.id, title: "الرد على بريد العميل",
                       status: .done, dueDate: day(0), completedAt: Milliseconds.now),
            TaskRecord(projectId: workProjectId, sectionId: backlog.id, title: "اجتماع الفريق الأسبوعي", dueDate: day(1),
                       dueTime: "09:30", recurrence: "FREQ=WEEKLY"),
            TaskRecord(projectId: workProjectId, sectionId: review.id, title: "تحديث لوحة المؤشرات", priority: .low,
                       dueDate: day(2)),
            TaskRecord(projectId: homeProjectId, sectionId: upkeep.id, title: "صيانة المكيّف", priority: .medium,
                       dueDate: day(3)),
            TaskRecord(projectId: learningProjectId, title: "إنهاء فصلين من كتاب الإدارة", dueDate: day(5), startDate: day(1)),
            TaskRecord(projectId: workProjectId, sectionId: backlog.id, title: "إعداد عرض المشروع الجديد", priority: .medium,
                       tags: ["عروض"], dueDate: day(7)),
            TaskRecord(projectId: homeProjectId, title: "دفع فاتورة الكهرباء", priority: .low, dueDate: day(10)),
            TaskRecord(title: "حجز موعد طبيب الأسنان"),
            TaskRecord(title: "ترتيب ملفات الحاسوب"),
        ]
        for (index, record) in tasks.enumerated() {
            let task = TaskItem(record, dirty: false)
            task.sortOrder = Double(index)
            context.insert(task)
        }

        // «قبل ١٥ د» and «عند الموعد», counted from each task's own time.
        context.insert(ReminderItem(ReminderRecord(taskId: reportTaskId, kind: .relative, offsetMinutes: -15), dirty: false))
        context.insert(ReminderItem(ReminderRecord(taskId: callTaskId, kind: .relative, offsetMinutes: 0), dirty: false))

        context.insert(PlaceItem(PlaceRecord(name: "البيت", latitude: 24.7136, longitude: 46.6753, radius: 150), dirty: false))
        context.insert(PlaceItem(PlaceRecord(name: "العمل", latitude: 24.6877, longitude: 46.7219, radius: 200), dirty: false))

        try? context.save()
    }
}
#endif
