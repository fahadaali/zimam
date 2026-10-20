import SwiftUI
import ZimamKit
#if canImport(UIKit)
import UIKit
#endif

// The sections of the settings pages (`SettingsView`).

/// «التقويم»: the main calendar and the first day of the week, saved through the bindings.
struct SettingsCalendarSection: View {
    let saveFailed: Bool
    @Binding var calendar: CalendarKind
    @Binding var weekStart: Int

    @Environment(SessionStore.self) private var session
    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Section {
            Picker("التقويم الأساسي", selection: $calendar) {
                Text("هجري").tag(CalendarKind.hijri)
                Text("ميلادي").tag(CalendarKind.gregorian)
            }
            .disabled(session.user == nil)
            Picker("بداية الأسبوع", selection: $weekStart) {
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
}

/// «الإشعارات»: the permission's state, and the way to turn alerts on.
struct SettingsNotificationsSection: View {
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(\.openURL) private var openURL

    #if os(iOS)
    private static var systemSettingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
    #else
    private static var systemSettingsURL: URL? { URL(string: "x-apple.systempreferences:com.apple.preference.notifications") }
    #endif

    var body: some View {
        Section("الإشعارات") {
            LabeledContent("الحالة", value: notifications.statusText)
            if notifications.canAskForAlerts {
                Button("تفعيل التنبيهات", systemImage: "bell", action: requestAlerts)
                    .frame(minHeight: ZimamSpacing.space11)
            }
            if notifications.isDenied, let url = Self.systemSettingsURL {
                Button("فتح إعدادات النظام", systemImage: "gear") { openURL(url) }
                    .frame(minHeight: ZimamSpacing.space11)
            }
        }
    }

    private func requestAlerts() {
        Task { await notifications.requestFullAuthorization() }
    }
}

/// «زمام الاحترافية»: the plan, and the paywall (Subscriptions/PaywallView.swift). While the
/// server does not enforce plans (the personal trial), nothing is locked and the footer says so.
struct SettingsSubscriptionSection: View {
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
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
}

/// «مزامنة الآن», with the last sync's error if it failed.
struct SettingsSyncSection: View {
    @Environment(SyncEngine.self) private var sync

    var body: some View {
        Section {
            Button("مزامنة الآن", systemImage: "arrow.triangle.2.circlepath", action: syncNow)
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

    private func syncNow() {
        Task { await sync.sync() }
    }
}

/// «الحساب»: sign-out and deletion, each confirmed first. The work itself is the settings
/// screen's (`onSignOut`, `onDeleteAccount`), which closes the whole sheet when it is done.
struct SettingsAccountSection: View {
    let isDeletingAccount: Bool
    let deleteFailed: Bool
    let onSignOut: () -> Void
    let onDeleteAccount: () -> Void

    @State private var confirmingSignOut = false
    @State private var confirmingDeleteAccount = false

    init(isDeletingAccount: Bool, deleteFailed: Bool,
         onSignOut: @escaping () -> Void, onDeleteAccount: @escaping () -> Void) {
        self.isDeletingAccount = isDeletingAccount
        self.deleteFailed = deleteFailed
        self.onSignOut = onSignOut
        self.onDeleteAccount = onDeleteAccount
    }

    var body: some View {
        Section {
            Button("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                confirmingSignOut = true
            }
            .frame(minHeight: ZimamSpacing.space11)
            .confirmationDialog("تسجيل الخروج؟", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("تسجيل الخروج", role: .destructive, action: onSignOut)
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
                Button("حذف الحساب", role: .destructive, action: onDeleteAccount)
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
}
