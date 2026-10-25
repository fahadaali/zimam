import SwiftData
import SwiftUI
import ZimamKit

// MARK: Reminders

/// «التذكيرات»: most count from the task's time (`TaskTimeRows`), so they move with its day and
/// its prayer: «عند الموعد», «قبل ١٥ د», «قبل يوم». A time of their own, a prayer of their own
/// and a place are in the same menu, after them.
struct TaskRemindersSection: View {
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(SessionStore.self) private var session
    @Environment(LocationProvider.self) private var location
    @Environment(\.dateFormatterZimam) private var formatter

    let task: TaskItem
    let reminders: [ReminderItem]
    let store: Store

    @State private var addingTime = false
    @State private var addingPrayer = false
    @State private var addingPlace = false

    private var hasPlaces: Bool {
        reminders.contains { $0.kindRaw == ReminderRecord.Kind.location.rawValue }
    }

    /// A day or a prayer to count from; an undated task at a prayer repeats daily.
    private var hasTime: Bool { task.dueDate != nil || task.duePrayer != nil }

    /// The relative ones first, soonest first; then the rest as they were added.
    private var sorted: [ReminderItem] {
        let relative = reminders.filter { $0.kindRaw == ReminderRecord.Kind.relative.rawValue }
            .sorted { ($0.offsetMinutes ?? 0) < ($1.offsetMinutes ?? 0) }
        return relative + reminders.filter { $0.kindRaw != ReminderRecord.Kind.relative.rawValue }
    }

    /// The offsets not added yet. An all-day task counts from the morning of its day, so only
    /// that morning and the day before make sense for it.
    private var presets: [Int] {
        let taken = Set(reminders.filter { $0.kindRaw == ReminderRecord.Kind.relative.rawValue }.map { $0.offsetMinutes ?? 0 })
        let offered = task.timeMode.isAllDay ? [0, -1440] : RelativeReminderPhrase.presets
        return offered.filter { !taken.contains($0) }
    }

    var body: some View {
        Section {
            ForEach(sorted) { reminder in
                TaskReminderRow(reminder: reminder, fireDate: fireDate(of: reminder)) { store.deleteReminder(reminder) }
            }

            Menu {
                if hasTime {
                    Section {
                        ForEach(presets, id: \.self) { offset in
                            Button(RelativeReminderPhrase.text(offset, locale: formatter.locale)) { addRelativeReminder(offset) }
                        }
                    }
                }
                Button("في وقت آخر…", systemImage: "calendar.badge.clock") { addingTime = true }
                Button("عند صلاة…", systemImage: "moon.stars") { addingPrayer = true }
                Button("عند مكان…", systemImage: "mappin.and.ellipse") { addingPlace = true }
            } label: {
                Label("إضافة تذكير", systemImage: "bell")
            }
            .frame(minHeight: ZimamSpacing.space11)
            .sheet(isPresented: $addingTime) {
                TimeReminderSheet(onAdd: addTimeReminder)
            }
            .sheet(isPresented: $addingPrayer) {
                PrayerReminderSheet(onAdd: addPrayerReminder)
            }
            .sheet(isPresented: $addingPlace) {
                LocationReminderSheet(onAdd: addLocationReminder)
            }
            #if os(iOS)
            if hasPlaces && !location.canWatchPlaces && !location.isUndecided,
               let url = LocationProvider.systemSettingsURL {
                Link(destination: url) {
                    Label(location.isDenied ? "السماح بالموقع لتذكيرات الموقع" : "تفعيل الموقع الدقيق لتذكيرات الموقع",
                          systemImage: "gear")
                }
                .frame(minHeight: ZimamSpacing.space11)
            }
            #endif
        } header: {
            Text("التذكيرات")
        } footer: {
            TaskRemindersFooter(hasTime: hasTime, isUnscheduled: task.dueDate == nil, hasPlaces: hasPlaces)
        }
        // A reminder added from a sheet that has just closed.
        .sensoryFeedback(.success, trigger: reminders.count) { old, new in new > old }
    }

    /// When a relative reminder fires next: on the task's day, or today for a daily prayer.
    private func fireDate(of reminder: ReminderItem) -> Date? {
        guard reminder.kindRaw == ReminderRecord.Kind.relative.rawValue else { return nil }
        let schedule = location.schedule(session.user?.settings)
        guard let time = TaskTiming.shownTime(of: task.timeMode, dueDay: task.dueDate, schedule: schedule, formatter: formatter)
                ?? task.dueDate.flatMap({ TaskTiming.time(of: .allDay, on: $0, schedule: nil, formatter: formatter) })
        else { return nil }
        return time.addingTimeInterval(TimeInterval((reminder.offsetMinutes ?? 0) * 60))
    }

    private func addRelativeReminder(_ offset: Int) {
        store.addRelativeReminder(to: task.id, offsetMinutes: offset)
        askForAlerts()
    }

    private func addTimeReminder(_ time: Date) {
        store.addTimeReminder(to: task.id, at: time)
        askForAlerts()
    }

    private func addPrayerReminder(_ prayer: Prayer, offset: Int) {
        store.addPrayerReminder(to: task.id, prayer: prayer, offsetMinutes: offset)
        askForAlerts()
    }

    private func addLocationReminder(_ place: ReminderRecord.Location, at time: Date?) {
        store.addLocationReminder(to: task.id, place: place, at: time)
        #if os(iOS)
        // Location while using the app lets the system watch the place; the sheet
        // offered «دائماً» with its reason.
        location.requestAuthorization()
        #endif
        askForAlerts()
    }

    private func askForAlerts() {
        Task { await notifications.requestFullAuthorization() }
    }
}

/// «في وقت آخر…»: a reminder at a time of its own, which stays where it is if the task moves.
private struct TimeReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dateFormatterZimam) private var formatter

    let onAdd: (Date) -> Void

    @State private var time = Date().addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("وقت التذكير", selection: $time, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Text(formatter.dual(time, withYear: true))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                } footer: {
                    Text("يبقى في وقته ولو تغيّر موعد المهمة.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("تذكير في وقت آخر")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إضافة") {
                        onAdd(time)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space8 * 12)
        #endif
    }
}

/// «عند صلاة…»: a reminder at a prayer other than the task's own time, on the task's day or
/// every day for a task without one.
private struct PrayerReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dateFormatterZimam) private var formatter

    let onAdd: (Prayer, Int) -> Void

    @State private var prayer: Prayer = .asr
    @State private var offset = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("الصلاة", selection: $prayer) {
                        ForEach(Prayer.allCases, id: \.self) { Text($0.arabicName).tag($0) }
                    }
                    Stepper(value: $offset, in: -120...120, step: 5) {
                        PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: offset, locale: formatter.locale))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("تذكير عند صلاة")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إضافة") {
                        onAdd(prayer, offset)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space8 * 12)
        #endif
    }
}

/// Why reminders may not arrive, and how place reminders behave on this device.
private struct TaskRemindersFooter: View {
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location

    /// The task has a day or a prayer, so reminders can count from it.
    let hasTime: Bool
    /// The task has no due day, so a prayer reminder repeats every day.
    let isUnscheduled: Bool
    let hasPlaces: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            if notifications.isDenied {
                Text("الإشعارات متوقفة لزمام. فعّلها من إعدادات النظام لتصلك التذكيرات.")
            } else if location.coordinate == nil {
                Text("تذكيرات الصلاة تحتاج موقعك. حدّده من الإعدادات.")
            } else if !hasTime {
                Text("حدّد موعداً للمهمة لتختار «عند الموعد» أو «قبل الموعد».")
            } else if isUnscheduled {
                Text("تذكير الصلاة لمهمة بلا تاريخ يتكرر كل يوم.")
            }
            if hasPlaces {
                #if os(iOS)
                Text("تذكير المكان وحده يصلك كلما وصلت أو غادرت حتى تنجز المهمة، والمرتبط بوقت يصلك مرة عند أيهما أسبق.")
                #else
                Text("تذكيرات الموقع تصل على الآيفون والآيباد، ولا تعمل على الماك.")
                #endif
            }
        }
    }
}

private struct TaskReminderRow: View {
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location

    let reminder: ReminderItem
    /// For a reminder relative to the task's time: when that comes to.
    let fireDate: Date?
    let onDelete: () -> Void

    /// Why a location reminder is not watched on this device, or nil when it is (or when
    /// notifications themselves are off, which the section's footer already says).
    private var placeNote: String? {
        let firing = reminder.firing()
        // Fired already: the row says so, and nothing is watched any more.
        guard firing.watchesPlace else { return nil }
        #if os(iOS)
        if !notifications.isEnabled { return nil }
        if notifications.watchedPlaces.contains(reminder.id) {
            if case .waiting = firing, location.needsAlways {
                return "قد يصلك التذكيران معاً. اسمح بالموقع «دائماً» ليصلك أيهما أسبق فقط."
            }
            return nil
        }
        if !location.canWatchPlaces {
            return location.isUndecided || location.isDenied
                ? "لا يعمل حتى تسمح لزمام بالموقع."
                : "لا يعمل حتى تفعّل «الموقع الدقيق» لزمام."
        }
        let limit = location.canMonitorPlaces ? PlaceWatchPlanner.maxPlaces : LocationReminderPlanner.maxRegions
        guard notifications.watchedPlaces.count >= limit else { return nil }
        let count = limit.formatted(.number.locale(formatter.locale))
        return "لا يعمل الآن: يراقب زمام \(count) \(limit > 10 ? "مكاناً" : "أماكن") على الأكثر، أقربها موعداً."
        #else
        if case .waiting = firing {
            return "يصلك هنا في الوقت فقط؛ المكان على الآيفون والآيباد."
        }
        return "لا يعمل على الماك، ويصلك على الآيفون والآيباد."
        #endif
    }

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(ZimamColor.inkMuted)
                    .frame(minWidth: ZimamSpacing.space11, minHeight: ZimamSpacing.space11)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("حذف التذكير")
        }
    }

    @ViewBuilder private var content: some View {
        switch ReminderRecord.Kind(rawValue: reminder.kindRaw) ?? .time {
        case .prayer:
            if let prayer = reminder.prayerRaw.flatMap({ Prayer(rawValue: $0) }) {
                PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: reminder.offsetMinutes, locale: formatter.locale))
            }
        case .relative:
            HStack(spacing: ZimamSpacing.space2) {
                Label(RelativeReminderPhrase.text(reminder.offsetMinutes ?? 0, locale: formatter.locale), systemImage: "bell")
                    .font(ZimamType.callout)
                    .foregroundStyle(fireDate.map { $0 < Date() } == true ? ZimamColor.inkFaint : ZimamColor.ink)
                if let fireDate {
                    Text("\(formatter.label(for: fireDate))، \(formatter.time(fireDate))")
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
        case .time:
            if let at = reminder.at, let date = ReminderPlanner.date(fromISO: at) {
                let text = "\(formatter.label(for: date))، \(formatter.time(date))"
                Label(text, systemImage: "bell")
                    .font(ZimamType.callout)
                    .foregroundStyle(date < Date() ? ZimamColor.inkFaint : ZimamColor.ink)
            }
        case .location:
            let place = reminder.record.location
            let firing = reminder.firing()
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Label(place.map { LocationReminderPlanner.reminderText($0, firing: firing, formatter: formatter) }
                          ?? LocationReminderPlanner.displayName(nil),
                      systemImage: place?.trigger == .leave ? "figure.walk.departure" : "figure.walk.arrival")
                    .font(ZimamType.callout)
                    .foregroundStyle(placeNote == nil && firing.watchesPlace ? ZimamColor.ink : ZimamColor.inkMuted)
                if let place {
                    Text("النطاق \(LocationReminderPlanner.radiusText(place.radius, locale: formatter.locale))")
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                if let placeNote {
                    Text(placeNote)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
        }
    }
}
