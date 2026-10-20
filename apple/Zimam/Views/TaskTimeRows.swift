import SwiftUI
import ZimamKit

// MARK: Time of day

/// «الوقت»: all day, a clock time, or around a prayer, in the task's details and «مهمة جديدة».
/// A prayer shows the time it gives on the task's day as an ordinary clock time, so a task a
/// month away shows that day's Asr. Changing that time by hand unties it from the prayer and
/// keeps the new time, as if it had been typed in.
struct TaskTimeRows: View {
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(SessionStore.self) private var session
    @Environment(LocationProvider.self) private var location

    let mode: TaskTimeMode
    /// The task's day ("2026-11-20"); nil for no day, where a prayer repeats every day.
    let day: String?
    let onChange: (TaskTimeMode) -> Void

    private enum Kind: Hashable { case allDay, clock, prayer }

    private var schedule: PrayerSchedule? { location.schedule(session.user?.settings) }

    /// The prayer's time on the task's day, or today's when it repeats daily.
    private var resolved: Date? {
        TaskTiming.shownTime(of: mode, dueDay: day, schedule: schedule, formatter: formatter)
    }

    private var kind: Binding<Kind> {
        Binding<Kind>(
            get: {
                switch mode {
                case .allDay: .allDay
                case .clock: .clock
                case .prayer: .prayer
                }
            },
            set: { kind in
                switch kind {
                case .allDay: onChange(.allDay)
                // From a prayer, its time stays as it was shown; otherwise the next whole hour.
                case .clock: onChange(.clock(resolved.map(clockString) ?? nextHour))
                case .prayer: onChange(.prayer(.asr, offsetMinutes: 0))
                }
            }
        )
    }

    var body: some View {
        Picker("الوقت", selection: kind) {
            Text("طوال اليوم").tag(Kind.allDay)
            Text("ساعة").tag(Kind.clock)
            Text("صلاة").tag(Kind.prayer)
        }
        .pickerStyle(.segmented)

        switch mode {
        case .allDay:
            EmptyView()
        case .clock:
            if let resolved {
                DatePicker("الساعة", selection: clockBinding(resolved), displayedComponents: .hourAndMinute)
            }
        case .prayer(let prayer, let offset):
            Picker("الصلاة", selection: prayerBinding(prayer, offset: offset)) {
                ForEach(Prayer.allCases, id: \.self) { Text($0.arabicName).tag($0) }
            }
            Stepper(value: offsetBinding(prayer, offset: offset), in: -120...120, step: 5) {
                PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: offset, locale: formatter.locale))
            }
            if let resolved {
                DatePicker(selection: clockBinding(resolved), displayedComponents: .hourAndMinute) {
                    Label {
                        Text("الساعة")
                    } icon: {
                        Image(systemName: "moon.stars")
                            .foregroundStyle(ZimamColor.sand)
                    }
                }
                Text(day == nil
                     ? "تتبع وقت \(prayer.arabicName) كل يوم. تعديل الساعة يفصلها عن الصلاة."
                     : "تتبع وقت \(prayer.arabicName) في يومها. تعديل الساعة يفصلها عن الصلاة.")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            } else if location.coordinate == nil {
                Text("حدّد موقعك لحساب وقت الصلاة.")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                LocationRequestRows()
            }
        }
    }

    /// A time picked by hand, which unties a prayer.
    private func clockBinding(_ current: Date) -> Binding<Date> {
        Binding(
            get: { current },
            set: { picked in onChange(.clock(clockString(picked))) }
        )
    }

    private func prayerBinding(_ prayer: Prayer, offset: Int) -> Binding<Prayer> {
        Binding(
            get: { prayer },
            set: { picked in onChange(.prayer(picked, offsetMinutes: offset)) }
        )
    }

    private func offsetBinding(_ prayer: Prayer, offset: Int) -> Binding<Int> {
        Binding(
            get: { offset },
            set: { picked in onChange(.prayer(prayer, offsetMinutes: picked)) }
        )
    }

    private func clockString(_ date: Date) -> String {
        TaskTiming.clockString(from: date, timeZone: formatter.timeZone)
    }

    /// An hour from now, on the hour: «٣:٠٠ م» at 2:20 p.m.
    private var nextHour: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        let hour = calendar.component(.hour, from: Date().addingTimeInterval(3600))
        return String(format: "%02d:00", hour)
    }
}
