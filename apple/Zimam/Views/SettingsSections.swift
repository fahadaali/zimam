import AuthenticationServices
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
            } else if let notice = sync.refusedNotice {
                Text(notice)
            } else {
                Text("تتزامن مهامك تلقائياً بين أجهزتك.")
            }
        }
    }

    private func syncNow() {
        Task { await sync.sync() }
    }
}

/// «الحساب»: sign-out and deletion, each confirmed first. Sign-out is the account menu's
/// (`signOutConfirmation`), with `onSignOut` closing the whole sheet first. Deletion asks twice:
/// the confirmation, then a fresh sign-in with Apple or Google (`ConfirmIdentitySheet`), whose
/// token goes to the settings screen's `onDeleteAccount`, which closes the sheet when it is done.
struct SettingsAccountSection: View {
    let isDeletingAccount: Bool
    /// Why the last deletion failed, if it did.
    let deleteError: String?
    let onSignOut: () -> Void
    let onDeleteAccount: (Reauthentication) -> Void

    @State private var signingOut = false
    @State private var confirmingDeleteAccount = false
    @State private var confirmingIdentity = false

    init(isDeletingAccount: Bool, deleteError: String?,
         onSignOut: @escaping () -> Void, onDeleteAccount: @escaping (Reauthentication) -> Void) {
        self.isDeletingAccount = isDeletingAccount
        self.deleteError = deleteError
        self.onSignOut = onSignOut
        self.onDeleteAccount = onDeleteAccount
    }

    var body: some View {
        Section {
            Button("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                signingOut = true
            }
            .disabled(signingOut)
            .frame(minHeight: ZimamSpacing.space11)
            .signOutConfirmation($signingOut, willSignOut: onSignOut)
            Button("حذف الحساب", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                confirmingDeleteAccount = true
            }
            .disabled(isDeletingAccount)
            .frame(minHeight: ZimamSpacing.space11)
            .confirmationDialog("حذف الحساب؟", isPresented: $confirmingDeleteAccount, titleVisibility: .visible) {
                Button("حذف الحساب", role: .destructive) { confirmingIdentity = true }
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("تُحذف مهامك ومشاريعك وتذكيراتك من خادم زمام ومن هذا الجهاز نهائياً، ولا يمكن استرجاعها. المشروع المشترك ينتقل إلى أقدم أعضائه. حذف الحساب لا يلغي اشتراك «زمام الاحترافية»: ألغه من إعدادات حسابك في App Store.")
            }
            .sheet(isPresented: $confirmingIdentity) {
                ConfirmIdentitySheet(onConfirmed: onDeleteAccount)
            }
        } header: {
            Text("الحساب")
        } footer: {
            if let deleteError {
                Text(deleteError)
                    .foregroundStyle(ZimamColor.priorityHigh)
            }
        }
    }
}

/// Before the account is deleted, the user signs in again with Apple or Google: the server
/// deletes it only with a fresh sign-in of an identity linked to it. The app does not know which
/// providers the account has, so both are offered (Google when it is set up). Only the provider's
/// token is read; the session stays as it is, and no new one is made. Closing this sheet, or the
/// provider's, deletes nothing and says nothing.
struct ConfirmIdentitySheet: View {
    let onConfirmed: (Reauthentication) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var isCheckingGoogle = false
    @State private var problem: String?

    /// One height for both buttons, as on the welcome screen (`SignInView`).
    @ScaledMetric(relativeTo: .headline) private var scaledButtonHeight = ZimamSpacing.space11
    private var buttonHeight: CGFloat { min(scaledButtonHeight, ZimamSpacing.space8 * 2) }

    init(onConfirmed: @escaping (Reauthentication) -> Void) {
        self.onConfirmed = onConfirmed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZimamSpacing.space4) {
                    Text("لتأكيد أنك صاحب الحساب، سجّل الدخول مرة أخرى بالحساب الذي تدخل به زمام. لا يُحذف شيء قبل ذلك.")
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: ZimamSpacing.space3) {
                        SignInWithAppleButton(.signIn) { request in
                            session.prepareReauthentication(request)
                        } onCompletion: { result in
                            finish(session.appleReauthentication(result))
                        }
                        // Black on the light theme, white on the dark one (Apple's guidelines).
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(maxWidth: .infinity)
                        .frame(height: buttonHeight)
                        .clipShape(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
                        .disabled(isCheckingGoogle)
                        if SessionStore.isGoogleConfigured {
                            GoogleButton(height: buttonHeight, isBusy: isCheckingGoogle, action: checkWithGoogle)
                        }
                    }
                    if let problem {
                        Text(problem)
                            .font(ZimamType.callout)
                            .foregroundStyle(ZimamColor.priorityHigh)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(ZimamSpacing.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ZimamColor.surface)
            .navigationTitle("تأكيد هويتك")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space8 * 8)
        #endif
    }

    private func checkWithGoogle() {
        problem = nil
        isCheckingGoogle = true
        Task {
            let check = await session.googleReauthentication()
            isCheckingGoogle = false
            finish(check)
        }
    }

    /// A token closes the sheet and starts the deletion; a cancelled sign-in closes it quietly.
    private func finish(_ check: SessionStore.IdentityCheck) {
        switch check {
        case .confirmed(let reauth):
            dismiss()
            onConfirmed(reauth)
        case .cancelled:
            dismiss()
        case .failed(let message):
            problem = message
        }
    }
}
