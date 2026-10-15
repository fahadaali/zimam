import SwiftUI
import ZimamKit
#if canImport(UIKit)
import UIKit
#endif

/// Calendar, prayer times, notifications and the account. Settings are saved
/// to the API (`PATCH /v1/me`) and applied at once, so dates switch calendars
/// as soon as the choice changes.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(LocationProvider.self) private var location
    @AppStorage(SessionStore.shareLocationKey) private var shareLocation = false
    @Environment(NotificationScheduler.self) private var notifications
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
                notificationsSection
                importSection
                accountSection
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("الإعدادات")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
            .confirmationDialog("تسجيل الخروج؟", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("تسجيل الخروج", role: .destructive, action: signOut)
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("تُمسح بيانات زمام من هذا الجهاز، وتبقى محفوظة في حسابك.")
            }
            .task { await notifications.refreshStatus() }
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

    private var prayerSection: some View {
        Section {
            Picker("طريقة الحساب", selection: methodBinding) {
                ForEach(PrayerMethod.allCases, id: \.self) { method in
                    Text(method.arabicName).tag(method)
                }
            }
            .disabled(session.user == nil)
            LocationRequestRows()
            if let schedule = location.schedule(method: settings.prayerMethod) {
                PrayerTimesList(schedule: schedule)
            }
            Toggle("أوقات الصلاة في كلود وChatGPT", isOn: $shareLocation)
                .frame(minHeight: ZimamSpacing.space11)
                .onChange(of: shareLocation) { _, _ in
                    Task {
                        await session.sharePlace(latitude: location.coordinate?.latitude,
                                                 longitude: location.coordinate?.longitude)
                    }
                }
        } header: {
            Text("أوقات الصلاة")
        } footer: {
            Text(shareLocation
                 ? "تُحسب الأوقات على جهازك، ويُحفظ في خادم زمام موقع تقريبي على مستوى المدينة لتظهر الأوقات في جدولك عند كلود وChatGPT."
                 : "تُحسب الأوقات على جهازك، ولا يُرسل موقعك إلى أي خادم.")
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
            Button("حذف الحساب", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                confirmingDeleteAccount = true
            }
            .disabled(isDeletingAccount)
            .frame(minHeight: ZimamSpacing.space11)
            .confirmationDialog("حذف الحساب؟", isPresented: $confirmingDeleteAccount, titleVisibility: .visible) {
                Button("حذف الحساب", role: .destructive, action: deleteAccount)
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("تُحذف مهامك ومشاريعك وتذكيراتك من خادم زمام ومن هذا الجهاز نهائياً، ولا يمكن استرجاعها. المشروع المشترك ينتقل إلى أقدم أعضائه.")
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

    private var methodBinding: Binding<PrayerMethod> {
        Binding(
            get: { settings.prayerMethod },
            set: { value in
                var updated = settings
                updated.prayerMethod = value
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
        Task {
            await session.signOut()
            try? sync.reset()
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
            try? sync.reset()
            dismiss()
        }
    }

    #if os(iOS)
    private static var systemSettingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
    #else
    private static var systemSettingsURL: URL? { URL(string: "x-apple.systempreferences:com.apple.preference.notifications") }
    #endif
}

/// Today's five prayer times in the sand colour reserved for prayer times, under the dual date.
private struct PrayerTimesList: View {
    let schedule: PrayerSchedule

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        let now = Date()
        let times = schedule.times(on: now)
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            Text(formatter.dual(now))
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            ForEach(Prayer.allCases, id: \.self) { prayer in
                if let time = times[prayer] {
                    PrayerTimeRow(name: prayer.arabicName, time: formatter.time(time))
                }
            }
        }
        .padding(.vertical, ZimamSpacing.space1)
    }
}

private struct PrayerTimeRow: View {
    let name: String
    let time: String

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            Label(name, systemImage: "moon.stars")
            Spacer(minLength: ZimamSpacing.space2)
            Text(time)
        }
        .font(ZimamType.callout)
        .foregroundStyle(ZimamColor.sand)
        .padding(.horizontal, ZimamSpacing.space3)
        .frame(minHeight: ZimamSpacing.space11)
        .background(ZimamColor.sandSoft, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
        .accessibilityElement(children: .combine)
    }
}
