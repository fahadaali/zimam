import SwiftUI
import ZimamKit

/// «أوقات الصلاة»: the next prayer with its countdown (or the time since the adhan, for half an
/// hour), today's times with sunrise, the place they are computed for (the device's location or a
/// place picked on the map), the calculation, and the adhan and iqama alerts of each prayer.
/// Opened from «اليوم» (`NextPrayerLine`) and from settings.
struct PrayerTimesView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LocationProvider.self) private var location
    @Environment(NotificationScheduler.self) private var notifications
    @AppStorage(SessionStore.shareLocationKey) private var shareLocation = false

    @State private var saveFailed = false
    @State private var pickingPlace = false

    var body: some View {
        Form {
            if let schedule = location.schedule(session.user?.settings) {
                Section {
                    PrayerClockCard(schedule: schedule)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    PrayerTimesList(schedule: schedule)
                } header: {
                    Text("مواقيت اليوم")
                }
            }
            placeSection
            calculationSection
            alertsSection
            shareSection
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle("أوقات الصلاة")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $pickingPlace) {
            PrayerPlacePicker()
        }
        .task { await notifications.refreshStatus() }
    }

    // MARK: Sections

    private var placeSection: some View {
        Section {
            if location.coordinate != nil {
                LabeledContent("المكان") {
                    Text(location.placeName ?? (location.isManual ? "مكان على الخريطة" : "موقعي الحالي"))
                        .foregroundStyle(ZimamColor.ink)
                }
                .frame(minHeight: ZimamSpacing.space11)
            }
            LocationRequestRows()
            Button("اختيار من الخريطة", systemImage: "map") { pickingPlace = true }
                .frame(minHeight: ZimamSpacing.space11)
        } header: {
            Text("الموقع")
        } footer: {
            Text(location.isManual
                 ? "تُحسب الأوقات للمكان الذي اخترته على الخريطة، ولا يغيّرها تنقّلك. اختر «استعمال موقعي الحالي» لتعود إلى موقعك."
                 : "تُحسب الأوقات لموقعك على مستوى المدينة. اختر مكاناً من الخريطة إن أردت مدينة أخرى.")
        }
    }

    private var calculationSection: some View {
        Section {
            Picker("طريقة الحساب", selection: binding(\.prayerMethod)) {
                ForEach(PrayerMethod.allCases, id: \.self) { method in
                    Text(method.arabicName).tag(method)
                }
            }
            Picker("وقت العصر", selection: madhabBinding) {
                ForEach(AsrMadhab.allCases, id: \.self) { madhab in
                    Text(madhab.arabicName).tag(madhab)
                }
            }
        } header: {
            Text("الحساب")
        } footer: {
            if saveFailed {
                Text("تعذّر حفظ الإعدادات. تحقّق من الاتصال وحاول مرة أخرى.")
                    .foregroundStyle(ZimamColor.priorityHigh)
            } else {
                Text("الجمهور: العصر حين يصير ظل الشيء مثله. الحنفي: حين يصير مثليه.")
            }
        }
        .disabled(session.user == nil)
    }

    @ViewBuilder
    private var alertsSection: some View {
        if !notifications.isEnabled {
            Section {
                if notifications.canAskForAlerts {
                    Button("تفعيل التنبيهات", systemImage: "bell") {
                        Task { await notifications.requestFullAuthorization() }
                    }
                    .frame(minHeight: ZimamSpacing.space11)
                } else {
                    Text("التنبيهات متوقفة. فعّلها لزمام من إعدادات النظام.")
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            } header: {
                Text("التنبيهات")
            }
        }
        ForEach(Prayer.allCases, id: \.self) { prayer in
            Section {
                Toggle("الأذان", isOn: alertBinding(prayer, \.adhan))
                    .frame(minHeight: ZimamSpacing.space11)
                Toggle("الإقامة", isOn: alertBinding(prayer, \.iqama))
                    .frame(minHeight: ZimamSpacing.space11)
                if alerts[prayer].iqama {
                    Stepper(value: alertBinding(prayer, \.iqamaMinutes), in: PrayerAlert.iqamaRange, step: 5) {
                        Text("بعد الأذان بـ\(minutes(alerts[prayer].iqamaMinutes)) دقيقة")
                    }
                    .frame(minHeight: ZimamSpacing.space11)
                }
            } header: {
                Text("تنبيه \(prayer.arabicName)")
            }
            .disabled(session.user == nil)
        }
    }

    private var shareSection: some View {
        Section {
            Toggle("أوقات الصلاة في كلود وChatGPT", isOn: $shareLocation)
                .frame(minHeight: ZimamSpacing.space11)
                .onChange(of: shareLocation) { _, _ in
                    Task {
                        await session.sharePlace(latitude: location.coordinate?.latitude,
                                                 longitude: location.coordinate?.longitude)
                    }
                }
        } footer: {
            Text(shareLocation
                 ? "تُحسب الأوقات على جهازك، ويُحفظ في خادم زمام موقع تقريبي على مستوى المدينة لتظهر الأوقات في جدولك عند كلود وChatGPT."
                 : "تُحسب الأوقات على جهازك، ولا يُرسل موقعك إلى أي خادم.")
        }
    }

    // MARK: Settings

    private var settings: User.Settings {
        session.user?.settings ?? User.Settings()
    }

    private var alerts: PrayerAlertSettings {
        settings.prayerAlerts ?? PrayerAlertSettings()
    }

    private func minutes(_ value: Int) -> String {
        value.formatted(.number.locale(ZimamLocale.current).grouping(.never))
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<User.Settings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                var updated = settings
                updated[keyPath: keyPath] = value
                save(updated)
            }
        )
    }

    private var madhabBinding: Binding<AsrMadhab> {
        Binding(
            get: { settings.asrMadhab ?? .shafi },
            set: { value in
                var updated = settings
                updated.asrMadhab = value
                save(updated)
            }
        )
    }

    private func alertBinding<Value>(_ prayer: Prayer, _ keyPath: WritableKeyPath<PrayerAlert, Value>) -> Binding<Value> {
        Binding(
            get: { alerts[prayer][keyPath: keyPath] },
            set: { value in
                var updatedAlerts = alerts
                updatedAlerts[prayer][keyPath: keyPath] = value
                var updated = settings
                updated.prayerAlerts = updatedAlerts
                save(updated)
                // Turning an alert on is the moment to ask for full alerts, as adding a reminder does.
                if updatedAlerts.isAnyOn, notifications.canAskForAlerts {
                    Task { await notifications.requestFullAuthorization() }
                }
            }
        )
    }

    private func save(_ updated: User.Settings) {
        guard updated != settings else { return }
        Task {
            let saved = await session.updateSettings(updated)
            saveFailed = !saved
            notifications.reschedule()
            ZimamShared.reloadWidgets()
        }
    }
}

// MARK: The clock

/// The next prayer and the time left, or for half an hour after an adhan the time since it.
/// The system counts the seconds (`Text(_:style: .timer)`); the state is recomputed every half
/// minute, so it moves on at the adhan and half an hour after it.
struct PrayerClockCard: View {
    let schedule: PrayerSchedule

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let state = PrayerClock(schedule: schedule).state(at: context.date) {
                content(state)
            }
        }
    }

    private func content(_ state: PrayerClock.State) -> some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            switch state {
            case .since(let prayer, _):
                Text("مضى على أذان \(prayer.arabicName)")
                    .font(ZimamType.callout)
            case .until(let prayer, _):
                Text("المتبقي على \(prayer.arabicName)")
                    .font(ZimamType.callout)
            }
            Text(state.time, style: .timer)
                .font(ZimamType.display)
                .monospacedDigit()
            Text("\(state.prayer.arabicName)، \(formatter.time(state.time))")
                .font(ZimamType.callout)
        }
        .foregroundStyle(ZimamColor.sand)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZimamSpacing.space4)
        .background(ZimamColor.sandSoft, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Today's times

/// Today's five prayer times and sunrise, in the sand colour reserved for prayer times, under the
/// dual date. The next prayer is marked.
struct PrayerTimesList: View {
    let schedule: PrayerSchedule

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let times = schedule.times(on: now)
            let next = schedule.next(after: now)
            VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                Text(formatter.dual(now))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                ForEach(Prayer.allCases, id: \.self) { prayer in
                    if let time = times[prayer] {
                        PrayerTimeRow(name: prayer.arabicName, systemImage: "moon.stars", time: formatter.time(time),
                                      isNext: next?.prayer == prayer && next?.time == time)
                    }
                    if prayer == .fajr, let sunrise = schedule.sunrise(on: now) {
                        PrayerTimeRow(name: "الشروق", systemImage: "sunrise", time: formatter.time(sunrise), isNext: false)
                    }
                }
            }
            .padding(.vertical, ZimamSpacing.space1)
        }
    }
}

struct PrayerTimeRow: View {
    let name: String
    let systemImage: String
    let time: String
    let isNext: Bool

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            Label(name, systemImage: systemImage)
            Spacer(minLength: ZimamSpacing.space2)
            if isNext {
                Text("القادمة")
                    .font(ZimamType.caption)
            }
            Text(time)
        }
        .font(isNext ? ZimamType.headline : ZimamType.callout)
        .foregroundStyle(ZimamColor.sand)
        .padding(.horizontal, ZimamSpacing.space3)
        .frame(minHeight: ZimamSpacing.space11)
        .background(ZimamColor.sandSoft, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
        .overlay {
            if isNext {
                RoundedRectangle(cornerRadius: ZimamRadius.radiusMd)
                    .stroke(ZimamColor.sand, lineWidth: ZimamLayout.focusRingWidth)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: From «اليوم»

/// The prayer screen on its own, from «اليوم»: a sheet works the same in every layout (the
/// iPhone's tabs, and the iPad's and Mac's columns, where «اليوم» has no stack to push on).
struct PrayerTimesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PrayerTimesView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("إغلاق") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: ZimamLayout.settingsWidth, minHeight: ZimamLayout.windowMinHeight)
        #endif
    }
}

/// «العصر بعد ١:١٢»: one line under the date on «اليوم» that opens the prayer screen
/// (`PrayerTimesSheet`). Without a place it offers to set one.
struct NextPrayerLine: View {
    let action: () -> Void

    @Environment(SessionStore.self) private var session
    @Environment(LocationProvider.self) private var location

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZimamSpacing.space2) {
                Image(systemName: "moon.stars")
                if let schedule = location.schedule(session.user?.settings) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let state = PrayerClock(schedule: schedule).state(at: context.date) {
                            line(state)
                        }
                    }
                } else {
                    Text("حدّد موقعك لتظهر أوقات الصلاة")
                }
                Spacer(minLength: ZimamSpacing.space2)
                Image(systemName: "chevron.forward")
                    .font(ZimamType.caption)
            }
            .font(ZimamType.callout)
            .foregroundStyle(ZimamColor.sand)
            .padding(.horizontal, ZimamSpacing.space3)
            .frame(minHeight: ZimamSpacing.space11)
            .background(ZimamColor.sandSoft, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func line(_ state: PrayerClock.State) -> some View {
        switch state {
        case .since(let prayer, let adhan):
            HStack(spacing: ZimamSpacing.space1) {
                Text("مضى على أذان \(prayer.arabicName)")
                Text(adhan, style: .timer).monospacedDigit()
            }
        case .until(let prayer, let time):
            HStack(spacing: ZimamSpacing.space1) {
                Text("\(prayer.arabicName) بعد")
                Text(time, style: .timer).monospacedDigit()
            }
        }
    }
}
