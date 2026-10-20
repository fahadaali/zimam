import SwiftUI
import ZimamKit

// MARK: «تغيير المدة…»

/// A task's start and due days without dragging, in the calendar the timeline shows. The start
/// can only be before the due day (its picker stops the day before).
struct SpanEditSheet: View {
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.dismiss) private var dismiss

    let task: TaskItem
    let kind: CalendarKind
    let onSave: (DaySpan) -> Void

    @State private var due: Date
    @State private var hasStart: Bool
    @State private var start: Date

    private var dates: DualDateFormatter { formatter.withKind(kind) }

    /// The day before the due day.
    private var latestStart: Date {
        DayMath.adding(-1, to: formatter.dayString(from: due)).flatMap { formatter.date(fromDay: $0) } ?? due
    }

    private var span: DaySpan {
        let end = formatter.dayString(from: due)
        let first = hasStart ? min(formatter.dayString(from: start), end) : end
        return DaySpan(start: first, end: end)
    }

    private var pickerCalendar: Calendar {
        var calendar = Calendar(identifier: kind.identifier)
        calendar.locale = formatter.locale
        calendar.timeZone = formatter.timeZone
        return calendar
    }

    init(task: TaskItem, kind: CalendarKind, onSave: @escaping (DaySpan) -> Void) {
        self.task = task
        self.kind = kind
        self.onSave = onSave
        let days = DualDateFormatter()
        let due = task.dueDate.flatMap { days.date(fromDay: $0) } ?? Calendar.current.startOfDay(for: Date())
        _due = State(initialValue: due)
        _hasStart = State(initialValue: task.startDate != nil)
        let dayBefore = DayMath.adding(-1, to: days.dayString(from: due)).flatMap { days.date(fromDay: $0) } ?? due
        _start = State(initialValue: task.startDate.flatMap { days.date(fromDay: $0) } ?? dayBefore)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("الاستحقاق", selection: $due, displayedComponents: .date)
                        .environment(\.calendar, pickerCalendar)
                        .environment(\.locale, formatter.locale)
                    Text(dates.dual(due, withYear: true))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                } header: {
                    Text(task.title)
                        .textCase(nil)
                }
                Section {
                    Toggle("تاريخ البداية", isOn: $hasStart)
                    if hasStart {
                        DatePicker("البداية", selection: $start, in: ...latestStart, displayedComponents: .date)
                            .environment(\.calendar, pickerCalendar)
                            .environment(\.locale, formatter.locale)
                        Text(dates.dual(start, withYear: true))
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                } footer: {
                    Text(dates.spanText(span))
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("تغيير المدة…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ", action: save)
                }
            }
            .onChange(of: due) { _, _ in clampStart() }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space8 * 12)
        #endif
    }

    // MARK: Actions

    private func save() {
        onSave(span)
        dismiss()
    }

    /// The start stays before the due day when the due day moves earlier.
    private func clampStart() {
        if start > latestStart { start = latestStart }
    }
}
