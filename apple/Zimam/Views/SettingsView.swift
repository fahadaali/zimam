import SwiftUI
#if os(iOS)
import UIKit
#endif
import ZimamKit

/// Settings: the account's photo and name on top (`AccountCard`), then one page per subject:
/// general (the calendar), prayer times, places, Siri, notifications, focus (iPhone), the subscription, import, and
/// the account (sync, sign-out, deletion). Settings are saved to the API (`PATCH /v1/me`) and
/// applied at once, so dates switch calendars as soon as the choice changes.
/// The sections of the pages are in SettingsSections.swift.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    @State private var saveFailed = false
    @State private var isDeletingAccount = false
    @State private var deleteFailed = false

    private var settings: User.Settings {
        session.user?.settings ?? User.Settings()
    }

    private var calendarBinding: Binding<CalendarKind> {
        Binding(
            get: { settings.calendar },
            set: { value in
                var updated = settings
                updated.calendar = value
                save(updated)
            }
        )
    }

    private var weekStartBinding: Binding<Int> {
        Binding(
            get: { settings.weekStart },
            set: { value in
                var updated = settings
                updated.weekStart = value
                save(updated)
            }
        )
    }

    init() {}

    var body: some View {
        NavigationStack {
            Form {
                AccountCard()
                Section {
                    SettingsPageRow("عام", systemImage: "calendar", value: settings.calendar == .hijri ? "هجري" : "ميلادي") {
                        Form {
                            SettingsCalendarSection(saveFailed: saveFailed, calendar: calendarBinding, weekStart: weekStartBinding)
                        }
                        .settingsPage("عام")
                    }
                    SettingsPageRow("أوقات الصلاة", systemImage: "moon.stars", value: location.placeName) {
                        PrayerTimesView()
                    }
                    SettingsPageRow("أماكني", systemImage: "mappin.and.ellipse") {
                        PlacesView()
                    }
                    SettingsPageRow("سيري", systemImage: "mic", value: ReminderBridge.shared.isOn ? "يستقبل التذكيرات" : nil) {
                        SiriSettingsView()
                    }
                    SettingsPageRow("الإشعارات", systemImage: "bell", value: notifications.isEnabled ? "مفعّلة" : "متوقفة") {
                        Form { SettingsNotificationsSection() }.settingsPage("الإشعارات")
                    }
                    #if os(iOS)
                    // «المهمة الجارية» is on the iPhone only (Views/FocusSection.swift).
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        SettingsPageRow("التركيز", systemImage: "moon", value: FocusDoNotDisturb.shared.isOn ? "مع عدم الإزعاج" : nil) {
                            FocusSettingsView()
                        }
                    }
                    #endif
                }
                Section {
                    SettingsPageRow("الاشتراك", systemImage: "star", value: subscriptions.isPro ? "الاحترافية" : "المجانية") {
                        Form { SettingsSubscriptionSection() }.settingsPage("الاشتراك")
                    }
                    SettingsPageRow("استيراد المهام", systemImage: "square.and.arrow.down") {
                        ImportView()
                    }
                }
                Section {
                    SettingsPageRow("الحساب والمزامنة", systemImage: "person.crop.circle") {
                        Form {
                            SettingsSyncSection()
                            SettingsAccountSection(
                                isDeletingAccount: isDeletingAccount,
                                deleteFailed: deleteFailed,
                                onSignOut: { dismiss() },
                                onDeleteAccount: { deleteAccount() }
                            )
                        }
                        .settingsPage("الحساب والمزامنة")
                    }
                }
                LegalLinksSection()
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("الإعدادات")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
            .task { await notifications.refreshStatus() }
            .task { await subscriptions.refresh(signedIn: session.isSignedIn, userId: session.user?.id) }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 14, minHeight: ZimamSpacing.space8 * 18)
        #endif
    }

    // MARK: Actions

    private func save(_ updated: User.Settings) {
        guard updated != settings else { return }
        Task {
            let saved = await session.updateSettings(updated)
            saveFailed = !saved
            notifications.reschedule()
        }
    }

    /// Waits for the server before wiping anything, then clears local data as sign-out does.
    private func deleteAccount() {
        isDeletingAccount = true
        deleteFailed = false
        Task {
            let deleted = await session.deleteAccount()
            isDeletingAccount = false
            guard deleted else {
                deleteFailed = true
                return
            }
            sync.reset()
            subscriptions.signedOut()
            dismiss()
        }
    }
}

/// One row that opens a page, with its current value at the trailing edge when it has one.
private struct SettingsPageRow<Destination: View>: View {
    let title: String
    let systemImage: String
    let value: String?
    let destination: () -> Destination

    init(_ title: String, systemImage: String, value: String? = nil,
         @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            LabeledContent {
                if let value {
                    Text(value)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
        .frame(minHeight: ZimamSpacing.space11)
    }
}

private extension View {
    /// A settings page: the Zimam background behind the form, and a small title.
    func settingsPage(_ title: String) -> some View {
        scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}
