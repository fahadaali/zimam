import SwiftData
import SwiftUI
import ZimamKit

// MARK: Reminders

struct TaskRemindersSection: View {
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location
    @Environment(\.dateFormatterZimam) private var formatter

    let task: TaskItem
    let reminders: [ReminderItem]
    let store: Store

    @State private var time = Date().addingTimeInterval(3600)
    @State private var prayer: Prayer = .asr
    @State private var offset = 0
    @State private var addingPlace = false

    private var hasPlaces: Bool {
        reminders.contains { $0.kindRaw == ReminderRecord.Kind.location.rawValue }
    }

    var body: some View {
        Section {
            ForEach(reminders) { reminder in
                TaskReminderRow(reminder: reminder) { store.deleteReminder(reminder) }
            }

            DatePicker("وقت التذكير", selection: $time, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            Text(formatter.dual(time, withYear: true))
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            Button("إضافة تذكير بالوقت", systemImage: "bell", action: addTimeReminder)
                .frame(minHeight: ZimamSpacing.space11)

            Picker("الصلاة", selection: $prayer) {
                ForEach(Prayer.allCases, id: \.self) { Text($0.arabicName).tag($0) }
            }
            Stepper(value: $offset, in: -120...120, step: 5) {
                PrayerChip(text: PrayerPhrase.text(prayer, offsetMinutes: offset, locale: formatter.locale))
            }
            Button("إضافة تذكير بالصلاة", systemImage: "moon.stars", action: addPrayerReminder)
                .frame(minHeight: ZimamSpacing.space11)

            Button("إضافة تذكير بالموقع", systemImage: "mappin.and.ellipse") { addingPlace = true }
                .frame(minHeight: ZimamSpacing.space11)
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
            TaskRemindersFooter(isUnscheduled: task.dueDate == nil, hasPlaces: hasPlaces)
        }
        // A reminder added from a sheet that has just closed.
        .sensoryFeedback(.success, trigger: reminders.count) { old, new in new > old }
    }

    private func addTimeReminder() {
        store.addTimeReminder(to: task.id, at: time)
        askForAlerts()
    }

    private func addPrayerReminder() {
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

/// Why reminders may not arrive, and how place reminders behave on this device.
private struct TaskRemindersFooter: View {
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location

    /// The task has no due day, so a prayer reminder repeats every day.
    let isUnscheduled: Bool
    let hasPlaces: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            if notifications.isDenied {
                Text("الإشعارات متوقفة لزمام. فعّلها من إعدادات النظام لتصلك التذكيرات.")
            } else if location.coordinate == nil {
                Text("تذكيرات الصلاة تحتاج موقعك. حدّده من الإعدادات.")
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
