import SwiftData
import SwiftUI
import ZimamKit

/// Adds a task: title, when it is due, an optional prayer anchor, priority and project.
struct AddTaskView: View {
    enum Due: Hashable { case unscheduled, today, tomorrow, pickedDate }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dateFormatterZimam) private var formatter
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete && $0.kindRaw == "project" }, sort: [SortDescriptor(\ProjectItem.sortOrder)])
    private var projects: [ProjectItem]

    @State private var title = ""
    @State private var due: Due
    @State private var pickedDate = Date()
    @State private var linkPrayer = false
    @State private var prayer: Prayer = .asr
    @State private var offset = 0
    @State private var priority: TaskPriority = .none
    @State private var projectId: UUID?
    @FocusState private var titleFocused: Bool

    init(due: Due = .unscheduled, projectId: UUID? = nil) {
        _due = State(initialValue: due)
        _projectId = State(initialValue: projectId)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("عنوان المهمة", text: $title)
                    .focused($titleFocused)
                    .onSubmit(add)

                Section {
                    Picker("الموعد", selection: $due) {
                        Text("بلا موعد").tag(Due.unscheduled)
                        Text("اليوم").tag(Due.today)
                        Text("غداً").tag(Due.tomorrow)
                        Text("تاريخ آخر").tag(Due.pickedDate)
                    }
                    if due == .pickedDate {
                        DatePicker("التاريخ", selection: $pickedDate, displayedComponents: .date)
                        Text(formatter.dual(pickedDate, withYear: true))
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                }

                Section {
                    Toggle("مرتبطة بوقت صلاة", isOn: $linkPrayer)
                    if linkPrayer {
                        Picker("الصلاة", selection: $prayer) {
                            ForEach(Prayer.allCases, id: \.self) { Text($0.arabicName).tag($0) }
                        }
                        Stepper(value: $offset, in: -120...120, step: 5) {
                            PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: offset, locale: formatter.locale))
                        }
                    }
                }

                Section {
                    Picker("الأولوية", selection: $priority) {
                        Text("بلا أولوية").tag(TaskPriority.none)
                        Text("منخفضة").tag(TaskPriority.low)
                        Text("متوسطة").tag(TaskPriority.medium)
                        Text("عالية").tag(TaskPriority.high)
                    }
                    if !projects.isEmpty {
                        Picker("المشروع", selection: $projectId) {
                            Text("صندوق المهام").tag(UUID?.none)
                            ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
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
        }
    }

    private func add() {
        guard !trimmedTitle.isEmpty else { return }
        let day: Date? = switch due {
        case .unscheduled: nil
        case .today: Date()
        case .tomorrow: Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case .pickedDate: pickedDate
        }
        Store(context: context, sync: sync).addTask(
            title: trimmedTitle,
            projectId: projectId,
            dueDate: day.map { formatter.dayString(from: $0) },
            duePrayer: linkPrayer ? prayer : nil,
            duePrayerOffset: linkPrayer ? offset : nil,
            priority: priority
        )
        dismiss()
    }
}
