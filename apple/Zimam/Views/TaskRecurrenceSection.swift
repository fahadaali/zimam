import SwiftData
import SwiftUI
import ZimamKit

// MARK: Recurrence

struct TaskRecurrenceSection: View {
    enum Choice: Hashable { case off, daily, weekly, monthly, yearly, custom }

    @Environment(\.dateFormatterZimam) private var formatter

    let task: TaskItem
    let store: Store

    private var rule: Recurrence? {
        guard let text = task.recurrence else { return nil }
        return Recurrence(rrule: text)
    }

    private var choice: Choice {
        guard let text = task.recurrence, !text.isEmpty else { return .off }
        guard let parsed = Recurrence(rrule: text) else { return .custom }
        switch parsed.frequency {
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }

    private var choiceBinding: Binding<Choice> {
        Binding(get: { choice }, set: { newChoice in choose(newChoice) })
    }

    /// The weekday of the due date, or of today.
    private var defaultWeekday: Weekday {
        let day = task.dueDate.flatMap { formatter.date(fromDay: $0) } ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        return Weekday(rawValue: calendar.component(.weekday, from: day)) ?? .sunday
    }

    var body: some View {
        let current = rule
        // No header: the picker's own label already says «التكرار», as in the priority card.
        Section {
            Picker("التكرار", selection: choiceBinding) {
                Text("بلا تكرار").tag(Choice.off)
                Text("يومياً").tag(Choice.daily)
                Text("أسبوعياً").tag(Choice.weekly)
                Text("شهرياً").tag(Choice.monthly)
                Text("سنوياً").tag(Choice.yearly)
                if choice == .custom {
                    Text("تكرار مخصص").tag(Choice.custom)
                }
            }
            if let current, current.frequency == .weekly {
                TaskWeekdayPicker(selected: current.weekdays) { day in toggle(day) }
            }
            if let current {
                Text(current.arabicDescription(locale: formatter.locale))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
    }

    private func choose(_ newChoice: Choice) {
        let frequency: Recurrence.Frequency
        switch newChoice {
        case .off:
            store.update(task) { item in item.recurrence = nil }
            return
        case .custom:
            return
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        let current = rule
        var interval = 1
        var weekdays: [Weekday] = []
        if let current, current.frequency == frequency {
            interval = current.interval
            weekdays = current.weekdays
        }
        if frequency == .weekly && weekdays.isEmpty {
            weekdays = [defaultWeekday]
        }
        let updated = Recurrence(frequency: frequency, interval: interval, weekdays: weekdays,
                                 count: current?.count, until: current?.until)
        store.update(task) { item in item.recurrence = updated.rrule }
    }

    /// Adds or removes a weekday; the last one cannot be removed.
    private func toggle(_ day: Weekday) {
        guard var updated = rule else { return }
        if let index = updated.weekdays.firstIndex(of: day) {
            guard updated.weekdays.count > 1 else { return }
            updated.weekdays.remove(at: index)
        } else {
            updated.weekdays.append(day)
            updated.weekdays.sort { $0.rawValue < $1.rawValue }
        }
        let text = updated.rrule
        store.update(task) { item in item.recurrence = text }
    }
}

private struct TaskWeekdayPicker: View {
    let selected: [Weekday]
    let onToggle: (Weekday) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: ZimamSpacing.space11 * 2), spacing: ZimamSpacing.space2)],
                  spacing: ZimamSpacing.space2) {
            ForEach(Weekday.allCases, id: \.self) { day in
                TaskWeekdayButton(day: day, isOn: selected.contains(day)) { onToggle(day) }
            }
        }
        .padding(.vertical, ZimamSpacing.space1)
    }
}

private struct TaskWeekdayButton: View {
    let day: Weekday
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(day.arabicName)
                .font(ZimamType.caption)
                .foregroundStyle(isOn ? ZimamColor.brandInk : ZimamColor.ink)
                .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
                .background(isOn ? ZimamColor.brandSoft : ZimamColor.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
                .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
                    .stroke(isOn ? ZimamColor.brand : ZimamColor.lineStrong))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
