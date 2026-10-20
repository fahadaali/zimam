import EventKit
import SwiftUI
import ZimamKit
#if os(iOS)
import UIKit
#endif

// MARK: The toolbar

/// «أحداث التقويم» in the calendar's toolbar: the switch, and the calendars to show.
struct CalendarEventsMenu: View {
    @Binding var showingSettings: Bool

    private var events: CalendarEvents { .shared }

    var body: some View {
        Menu {
            Toggle("إظهار أحداث التقويم", isOn: Binding(
                get: { events.isShowing },
                set: { on in setShowing(on) }
            ))
            Button("اختيار التقاويم…", systemImage: "checklist") { showingSettings = true }
        } label: {
            Label("أحداث التقويم", systemImage: events.isShowing ? "calendar.badge.checkmark" : "calendar")
        }
        .accessibilityHint("يُظهر أحداث تقويم أبل مع المهام أو يخفيها")
    }

    private func setShowing(_ on: Bool) {
        Task {
            await events.setShowing(on)
            // No access yet: the sheet says why and how to allow it.
            if on && events.access != .granted { showingSettings = true }
        }
    }
}

/// The permission's states, shared by the events' settings and the import screen.
struct CalendarAccessSection: View {
    let access: CalendarEvents.Access
    /// What reading is for, under the request button.
    let purpose: String
    let onRequest: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        switch access {
        case .notDetermined:
            Section {
                Button("السماح بالوصول إلى التقويم", systemImage: "calendar", action: onRequest)
                    .frame(minHeight: ZimamSpacing.space11)
            } footer: {
                Text(purpose)
            }
        case .writeOnly, .denied:
            Section {
                Text(access == .writeOnly
                     ? "لزمام إذن الإضافة إلى التقويم فقط. اسمح له بالوصول الكامل من إعدادات النظام ليقرأ الأحداث."
                     : "لم يُسمح لزمام بقراءة التقويم. اسمح له من إعدادات النظام ثم ارجع إلى هنا.")
                if let url = Self.settingsURL {
                    Button("فتح إعدادات النظام", systemImage: "gear") { openURL(url) }
                        .frame(minHeight: ZimamSpacing.space11)
                }
            }
        case .restricted:
            Section {
                Text("الوصول إلى التقويم مقيّد على هذا الجهاز.")
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        case .granted:
            EmptyView()
        }
    }

    #if os(iOS)
    private static var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
    #else
    private static var settingsURL: URL? { URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") }
    #endif
}

/// A calendar's row: its marker, its name and its account.
struct CalendarChoiceLabel: View {
    let calendar: AppleCalendarImport.CalendarRef
    let color: Color

    var body: some View {
        HStack(spacing: ZimamSpacing.space3) {
            EventMarker(color: color)
            VStack(alignment: .leading, spacing: 0) {
                Text(calendar.title)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
                if !calendar.sourceTitle.isEmpty {
                    Text(calendar.sourceTitle)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
        }
    }
}

/// «أحداث التقويم»: the switch, the permission, and which calendars to show.
struct CalendarEventsSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var events: CalendarEvents { .shared }

    var body: some View {
        NavigationStack {
            Form {
                CalendarEventsShowSection()
                CalendarAccessSection(access: events.access,
                                      purpose: "يطلب النظام إذنك مرة واحدة. يقرأ زمام الأحداث ليعرضها فقط، ولا يغيّر التقويم.") {
                    requestAccess()
                }
                if events.access == .granted {
                    CalendarShownCalendarsSection()
                }
                if let message = events.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(ZimamColor.priorityHigh)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("أحداث التقويم")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
            .task { events.refresh() }
            .onChange(of: scenePhase) { _, phase in
                scenePhaseChanged(phase)
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space8 * 14)
        #endif
    }

    private func requestAccess() {
        Task { await events.requestAccess() }
    }

    private func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .active { events.refresh() }
    }
}

/// «إظهار أحداث التقويم», and what showing them means.
struct CalendarEventsShowSection: View {
    private var events: CalendarEvents { .shared }

    var body: some View {
        Section {
            Toggle("إظهار أحداث التقويم", isOn: Binding(
                get: { events.isShowing },
                set: { on in setShowing(on) }
            ))
            .frame(minHeight: ZimamSpacing.space11)
        } footer: {
            Text("تظهر أحداث تقويم أبل في التقويم و«اليوم» للاطلاع فقط. تبقى على جهازك، ولا يُضاف منها إلى حسابك إلا ما تحوّله إلى مهمة.")
        }
    }

    private func setShowing(_ on: Bool) {
        Task { await events.setShowing(on) }
    }
}

/// «التقاويم المعروضة»: a switch per calendar on the device.
struct CalendarShownCalendarsSection: View {
    private var events: CalendarEvents { .shared }

    var body: some View {
        Section {
            if events.calendars.isEmpty {
                Text("لا تقاويم على هذا الجهاز.")
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            ForEach(events.calendars) { calendar in
                Toggle(isOn: shownBinding(calendar.id)) {
                    CalendarChoiceLabel(calendar: calendar, color: events.color(for: calendar.id))
                }
                .frame(minHeight: ZimamSpacing.space11)
            }
        } header: {
            Text("التقاويم المعروضة")
        }
    }

    private func shownBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { events.isShown(id) },
            set: { events.setCalendar(id, shown: $0) }
        )
    }
}
