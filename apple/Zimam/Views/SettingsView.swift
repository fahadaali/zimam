import SwiftUI
import ZimamKit
#if canImport(UIKit)
import UIKit
#endif

/// Settings: the account's photo and name on top (`AccountCard`), then one page per subject:
/// general (the calendar), prayer times, places, notifications, the subscription, import, and
/// the account (sync, sign-out, deletion). Settings are saved to the API (`PATCH /v1/me`) and
/// applied at once, so dates switch calendars as soon as the choice changes.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var saveFailed = false
    @State private var confirmingSignOut = false
    @State private var confirmingDeleteAccount = false
    @State private var isDeletingAccount = false
    @State private var deleteFailed = false

    init() {}

    var body: some View {
        NavigationStack {
            Form {
                AccountCard()
                Section {
                    page("عام", systemImage: "calendar", value: settings.calendar == .hijri ? "هجري" : "ميلادي") {
                        Form { calendarSection }.settingsPage("عام")
                    }
                    page("أوقات الصلاة", systemImage: "moon.stars", value: location.placeName) {
                        PrayerTimesView()
                    }
                    page("أماكني", systemImage: "mappin.and.ellipse") {
                        PlacesView()
                    }
                    page("سيري", systemImage: "mic", value: ReminderBridge.shared.isOn ? "يستقبل التذكيرات" : nil) {
                        SiriSettingsView()
                    }
                    page("الإشعارات", systemImage: "bell", value: notifications.isEnabled ? "مفعّلة" : "متوقفة") {
                        Form { notificationsSection }.settingsPage("الإشعارات")
                    }
                }
                Section {
                    page("الاشتراك", systemImage: "star", value: subscriptions.isPro ? "الاحترافية" : "المجانية") {
                        Form { subscriptionSection }.settingsPage("الاشتراك")
                    }
                    page("استيراد المهام", systemImage: "square.and.arrow.down") {
                        ImportView()
                    }
                }
                Section {
                    page("الحساب والمزامنة", systemImage: "person.crop.circle") {
                        Form {
                            syncSection
                            accountSection
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
            .task { await subscriptions.refresh(signedIn: session.isSignedIn) }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 14, minHeight: ZimamSpacing.space8 * 18)
        #endif
    }

    // MARK: Pages

    /// One row that opens a page, with its current value at the trailing edge when it has one.
    private func page<Destination: View>(_ title: String, systemImage: String, value: String? = nil,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
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

    // MARK: Sections

    /// «مزامنة الآن», with the last sync's error if it failed.
    private var syncSection: some View {
        Section {
            Button("مزامنة الآن", systemImage: "arrow.triangle.2.circlepath") {
                Task { await sync.sync() }
            }
            .frame(minHeight: ZimamSpacing.space11)
        } header: {
            Text("المزامنة")
        } footer: {
            if let error = sync.lastError {
                Text(error)
                    .foregroundStyle(ZimamColor.priorityHigh)
            } else {
                Text("تتزامن مهامك تلقائياً بين أجهزتك.")
            }
        }
    }

    private var calendarSection: some View {
        Section {
            Picker("التقويم الأساسي", selection: calendarBinding) {
                Text("هجري").tag(CalendarKind.hijri)
                Text("ميلادي").tag(CalendarKind.gregorian)
            }
            .disabled(session.user == nil)
            Picker("بداية الأسبوع", selection: weekStartBinding) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    Text(day.arabicName).tag(day.rawValue - 1)
                }
            }
            .disabled(session.user == nil)
            Text(formatter.dual(Date(), withYear: true))
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
        } header: {
            Text("التقويم")
        } footer: {
            if saveFailed {
                Text("تعذّر حفظ الإعدادات. تحقّق من الاتصال وحاول مرة أخرى.")
                    .foregroundStyle(ZimamColor.priorityHigh)
            }
        }
    }

    private var notificationsSection: some View {
        Section("الإشعارات") {
            LabeledContent("الحالة", value: notifications.statusText)
            if notifications.canAskForAlerts {
                Button("تفعيل التنبيهات", systemImage: "bell") {
                    Task { await notifications.requestFullAuthorization() }
                }
                .frame(minHeight: ZimamSpacing.space11)
            }
            if notifications.isDenied, let url = Self.systemSettingsURL {
                Button("فتح إعدادات النظام", systemImage: "gear") { openURL(url) }
                    .frame(minHeight: ZimamSpacing.space11)
            }
        }
    }

    /// «زمام الاحترافية»: the plan, and the paywall (Subscriptions/PaywallView.swift). While the
    /// server does not enforce plans (the personal trial), nothing is locked and the footer says so.
    private var subscriptionSection: some View {
        Section {
            LabeledContent("الباقة", value: subscriptions.isPro ? "الاحترافية" : "المجانية")
            if subscriptions.isPro, let end = subscriptions.plan?.expiresDate {
                LabeledContent("الفترة الحالية حتى", value: formatter.dual(end, withYear: true))
            }
            NavigationLink {
                PaywallContent()
            } label: {
                Label(subscriptions.isPro ? "إدارة الاشتراك" : ZimamPro.groupName, systemImage: "star")
            }
            .frame(minHeight: ZimamSpacing.space11)
        } header: {
            Text("الاشتراك")
        } footer: {
            if !subscriptions.isEnforced {
                Text("في فترة التجربة كل المزايا متاحة دون اشتراك.")
            }
        }
    }

    private var accountSection: some View {
        Section {
            Button("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                confirmingSignOut = true
            }
            .frame(minHeight: ZimamSpacing.space11)
            .confirmationDialog("تسجيل الخروج؟", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("تسجيل الخروج", role: .destructive, action: signOut)
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("تُمسح بيانات زمام من هذا الجهاز، وتبقى محفوظة في حسابك.")
            }
            Button("حذف الحساب", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                confirmingDeleteAccount = true
            }
            .disabled(isDeletingAccount)
            .frame(minHeight: ZimamSpacing.space11)
            .confirmationDialog("حذف الحساب؟", isPresented: $confirmingDeleteAccount, titleVisibility: .visible) {
                Button("حذف الحساب", role: .destructive, action: deleteAccount)
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("تُحذف مهامك ومشاريعك وتذكيراتك من خادم زمام ومن هذا الجهاز نهائياً، ولا يمكن استرجاعها. المشروع المشترك ينتقل إلى أقدم أعضائه. حذف الحساب لا يلغي اشتراك «زمام الاحترافية»: ألغه من إعدادات حسابك في App Store.")
            }
        } header: {
            Text("الحساب")
        } footer: {
            if deleteFailed {
                Text("تعذّر حذف الحساب. تحقّق من الاتصال وحاول مرة أخرى.")
                    .foregroundStyle(ZimamColor.priorityHigh)
            }
        }
    }

    // MARK: Settings

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

    private func save(_ updated: User.Settings) {
        guard updated != settings else { return }
        Task {
            let saved = await session.updateSettings(updated)
            saveFailed = !saved
            notifications.reschedule()
        }
    }

    private func signOut() {
        dismiss()
        subscriptions.signedOut()
        Task {
            await session.signOut()
            sync.reset()
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

    #if os(iOS)
    private static var systemSettingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
    #else
    private static var systemSettingsURL: URL? { URL(string: "x-apple.systempreferences:com.apple.preference.notifications") }
    #endif
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
