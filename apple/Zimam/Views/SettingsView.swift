import SwiftUI
import ZimamKit
#if canImport(UIKit)
import UIKit
#endif

/// Calendar, prayer times, saved places, notifications and the account. Settings are saved
/// to the API (`PATCH /v1/me`) and applied at once, so dates switch calendars
/// as soon as the choice changes.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(NotificationScheduler.self) private var notifications
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
                calendarSection
                prayerSection
                placesSection
                notificationsSection
                subscriptionSection
                importSection
                accountSection
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

    // MARK: Sections

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

    /// «أوقات الصلاة» has its own screen: the place, the calculation, and the adhan and iqama alerts.
    private var prayerSection: some View {
        Section {
            NavigationLink {
                PrayerTimesView()
            } label: {
                Label("أوقات الصلاة", systemImage: "moon.stars")
            }
            .frame(minHeight: ZimamSpacing.space11)
        } footer: {
            Text("المواقيت، والموقع، وطريقة الحساب، وتنبيهات الأذان والإقامة.")
        }
    }

    /// «أماكني»: places the user names once and reuses for location reminders.
    private var placesSection: some View {
        Section {
            NavigationLink {
                PlacesView()
            } label: {
                Label("أماكني", systemImage: "mappin.and.ellipse")
            }
            .frame(minHeight: ZimamSpacing.space11)
        } footer: {
            Text("البيت والعمل وغيرهما، لتذكيرك بمهمة حين تصل إلى المكان أو تغادره.")
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

    /// Tasks from Todoist, TickTick, Google Tasks, a CSV file or Apple Reminders (Import/ImportView.swift).
    private var importSection: some View {
        Section {
            NavigationLink {
                ImportView()
            } label: {
                Label("استيراد المهام", systemImage: "square.and.arrow.down")
            }
            .frame(minHeight: ZimamSpacing.space11)
        } header: {
            Text("الاستيراد")
        } footer: {
            Text("انقل مهامك من Todoist أو TickTick أو Google Tasks أو تذكيرات أبل أو ملف CSV.")
        }
    }

    private var accountSection: some View {
        Section {
            if let name = session.user?.name {
                LabeledContent("الاسم", value: name)
            }
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
