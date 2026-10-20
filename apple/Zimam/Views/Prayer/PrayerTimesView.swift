import SwiftUI
import ZimamKit

/// «أوقات الصلاة»: the next prayer with its countdown (or the time since the adhan, for half an
/// hour), today's times with sunrise, the place they are computed for (the device's location or a
/// place picked on the map), the calculation, and the adhan and iqama alerts of each prayer.
/// Opened from «اليوم» (`NextPrayerLine`) and from settings. The clock and today's times are in
/// PrayerClockViews.swift, the other sections in PrayerTimesSections.swift.
struct PrayerTimesView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LocationProvider.self) private var location
    @Environment(NotificationScheduler.self) private var notifications

    @State private var saveFailed = false
    @State private var pickingPlace = false

    private var settings: User.Settings {
        session.user?.settings ?? User.Settings()
    }

    private var alerts: PrayerAlertSettings {
        settings.prayerAlerts ?? PrayerAlertSettings()
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
            PrayerLocationSection { pickingPlace = true }
            PrayerCalculationSection(method: binding(\.prayerMethod), madhab: madhabBinding, saveFailed: saveFailed)
            PrayerAlertsStatusSection()
            ForEach(Prayer.allCases, id: \.self) { prayer in
                PrayerAlertSection(prayer: prayer, alert: alertBinding(prayer))
            }
            PrayerShareSection()
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

    // MARK: Settings

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

    private func alertBinding(_ prayer: Prayer) -> Binding<PrayerAlert> {
        Binding(
            get: { alerts[prayer] },
            set: { value in
                var updatedAlerts = alerts
                updatedAlerts[prayer] = value
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
