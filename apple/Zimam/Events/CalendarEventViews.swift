import EventKit
import SwiftData
import SwiftUI
import ZimamKit
#if os(iOS)
import EventKitUI
import UIKit
#endif

// Apple Calendar events over Zimam's calendar and «اليوم», read only. An event is outlined, never
// filled, so it never reads as a task: its calendar's color is a small marker, its text is in
// Zimam's ink. All-day events and events that span days are bars; timed events show their time.

// MARK: Words

extension ArabicCount {
    /// «حدث واحد»، «حدثان»، «٣ أحداث»، «١١ حدثاً»، «١٠٠ حدث».
    static func events(_ count: Int, locale: Locale) -> String {
        let number = count.formatted(.number.locale(locale))
        switch count {
        case 1: return "حدث واحد"
        case 2: return "حدثان"
        default:
            switch count % 100 {
            case 3...10: return "\(number) أحداث"
            case 11...99: return "\(number) حدثاً"
            default: return "\(number) حدث"
            }
        }
    }
}

extension DualDateFormatter {
    /// The short line under an event in a list: «١٠:٠٠ ص – ١١:٠٠ ص», «طوال اليوم», or its days.
    func eventTime(_ item: ShownEvent) -> String {
        if item.span.isMultiDay { return spanText(item.span) }
        if item.event.isAllDay { return "طوال اليوم" }
        return "\(time(item.event.start)) – \(time(item.event.end))"
    }

    /// When the event is, in both calendars, for its details.
    func eventWhen(_ item: ShownEvent) -> [String] {
        let event = item.event
        if item.span.isMultiDay {
            if event.isAllDay { return [spanText(item.span)] }
            return ["يبدأ \(weekday(event.start))، \(dual(event.start, withYear: true))، \(time(event.start))",
                    "وينتهي \(weekday(event.end))، \(dual(event.end, withYear: true))، \(time(event.end))"]
        }
        let day = "\(weekday(event.start))، \(dual(event.start, withYear: true))"
        if event.isAllDay { return [day, "طوال اليوم"] }
        return [day, "\(time(event.start)) – \(time(event.end))"]
    }

    /// For VoiceOver: «اجتماع الفريق، ١٠:٠٠ ص – ١١:٠٠ ص، حدث في تقويم العمل».
    func eventAccessibility(_ item: ShownEvent) -> String {
        "\(item.title)، \(eventTime(item))، حدث في تقويم \(item.calendarTitle)"
    }
}

// MARK: Pieces

/// The calendar's color as a small dot: the only place its color is used.
struct EventMarker: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: ZimamSpacing.space2, height: ZimamSpacing.space2)
            .accessibilityHidden(true)
    }
}

/// An event in a day list: outlined, with its marker, title and time. Opens its details.
struct EventRow: View {
    let item: ShownEvent
    let onOpen: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: ZimamSpacing.space3) {
                EventMarker(color: item.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(formatter.eventTime(item))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: ZimamSpacing.space2)
                Image(systemName: "calendar")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ZimamSpacing.space3)
            .padding(.vertical, ZimamSpacing.space2)
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd).strokeBorder(ZimamColor.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(formatter.eventAccessibility(item))
        .accessibilityHint("يعرض تفاصيل الحدث")
    }
}

/// A day's events above its tasks: bars (all-day, spanning) first, then timed ones.
struct DayEventsList: View {
    let events: [ShownEvent]
    let onOpen: (ShownEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            ForEach(events) { item in
                EventRow(item: item) { onOpen(item) }
            }
        }
    }
}

/// Up to three outlined rings in a month cell (tasks are filled dots), or the count when more.
struct EventMarks: View {
    let count: Int

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        HStack(spacing: ZimamSpacing.space1 / 2) {
            if count > 3 {
                Text(formatter.number(count))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            } else {
                ForEach(0..<count, id: \.self) { _ in
                    Circle()
                        .strokeBorder(ZimamColor.inkMuted, lineWidth: ZimamSpacing.space1 / 4)
                        .frame(width: ZimamSpacing.space1 * 1.5, height: ZimamSpacing.space1 * 1.5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// All-day events and events that span days, as outlined bars across the week's columns (iPad, Mac).
struct EventLanes: View {
    let days: [String]
    let events: [ShownEvent]
    var maxLanes = 3
    let spacing: CGFloat
    let onOpen: (ShownEvent) -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        let bars = events.filter(\.isWholeDay)
        let segments = SpanLayout.week(bars.map { (id: $0.id, span: $0.span) }, days: days, maxLanes: maxLanes).segments
        if !segments.isEmpty && !days.isEmpty {
            let laneHeight = ZimamSpacing.space11
            let lanes = (segments.map(\.lane).max() ?? 0) + 1
            let height = laneHeight * CGFloat(lanes) + spacing * CGFloat(lanes - 1)
            GeometryReader { geometry in
                let columnCount = days.count
                let column = (geometry.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
                ZStack(alignment: .topLeading) {
                    ForEach(segments, id: \.self) { segment in
                        if let item = bars.first(where: { $0.id == segment.id }) {
                            bar(item)
                                .frame(width: column * CGFloat(segment.columnCount) + spacing * CGFloat(segment.columnCount - 1),
                                       height: laneHeight)
                                .padding(.leading, (column + spacing) * CGFloat(segment.firstColumn))
                                .padding(.top, (laneHeight + spacing) * CGFloat(segment.lane))
                        }
                    }
                }
                .frame(width: geometry.size.width, height: height, alignment: .topLeading)
            }
            .frame(height: height)
        }
    }

    private func bar(_ item: ShownEvent) -> some View {
        Button { onOpen(item) } label: {
            HStack(spacing: ZimamSpacing.space2) {
                EventMarker(color: item.color)
                Text(item.title)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, ZimamSpacing.space2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusSm))
            .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusSm).strokeBorder(ZimamColor.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(formatter.eventAccessibility(item))
    }
}

/// A timed event in a week column (iPad, Mac): outlined, its title and start time.
struct WeekEventCard: View {
    let item: ShownEvent
    let onOpen: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                HStack(spacing: ZimamSpacing.space1) {
                    EventMarker(color: item.color)
                    Text(formatter.time(item.event.start))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                Text(item.title)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(ZimamSpacing.space2)
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd).strokeBorder(ZimamColor.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(formatter.eventAccessibility(item))
    }
}

// MARK: The toolbar

/// «أحداث التقويم» in the calendar's toolbar: the switch, and the calendars to show.
struct CalendarEventsMenu: View {
    @Binding var showingSettings: Bool

    private var events: CalendarEvents { .shared }

    var body: some View {
        Menu {
            Toggle("إظهار أحداث التقويم", isOn: Binding(
                get: { events.isShowing },
                set: { on in
                    Task {
                        await events.setShowing(on)
                        // No access yet: the sheet says why and how to allow it.
                        if on && events.access != .granted { showingSettings = true }
                    }
                }
            ))
            Button("اختيار التقاويم…", systemImage: "checklist") { showingSettings = true }
        } label: {
            Label("أحداث التقويم", systemImage: events.isShowing ? "calendar.badge.checkmark" : "calendar")
        }
        .accessibilityHint("يُظهر أحداث تقويم أبل مع المهام أو يخفيها")
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
                Section {
                    Toggle("إظهار أحداث التقويم", isOn: Binding(
                        get: { events.isShowing },
                        set: { on in Task { await events.setShowing(on) } }
                    ))
                    .frame(minHeight: ZimamSpacing.space11)
                } footer: {
                    Text("تظهر أحداث تقويم أبل في التقويم و«اليوم» للاطلاع فقط. تبقى على جهازك، ولا يُضاف منها إلى حسابك إلا ما تحوّله إلى مهمة.")
                }
                CalendarAccessSection(access: events.access,
                                      purpose: "يطلب النظام إذنك مرة واحدة. يقرأ زمام الأحداث ليعرضها فقط، ولا يغيّر التقويم.") {
                    Task { await events.requestAccess() }
                }
                if events.access == .granted {
                    Section {
                        if events.calendars.isEmpty {
                            Text("لا تقاويم على هذا الجهاز.")
                                .foregroundStyle(ZimamColor.inkMuted)
                        }
                        ForEach(events.calendars) { calendar in
                            Toggle(isOn: Binding(
                                get: { events.isShown(calendar.id) },
                                set: { events.setCalendar(calendar.id, shown: $0) }
                            )) {
                                CalendarChoiceLabel(calendar: calendar, color: events.color(for: calendar.id))
                            }
                            .frame(minHeight: ZimamSpacing.space11)
                        }
                    } header: {
                        Text("التقاويم المعروضة")
                    }
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
                if phase == .active { events.refresh() }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space8 * 14)
        #endif
    }
}

// MARK: Details

/// An event's details: when (both calendars), where, its notes and calendar, with «تحويل إلى مهمة»
/// and «فتح في التقويم».
struct CalendarEventSheet: View {
    let item: ShownEvent

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var converted = false
    #if os(iOS)
    @State private var systemEvent: SystemEvent?
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.title)
                        .font(ZimamType.title)
                        .foregroundStyle(ZimamColor.ink)
                        .lineSpacing(ZimamType.titleLineSpacing)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(formatter.eventWhen(item), id: \.self) { line in
                        Text(line)
                            .font(ZimamType.callout)
                            .foregroundStyle(ZimamColor.ink)
                    }
                }
                if let location = trimmed(item.event.location) {
                    Section("المكان") {
                        Text(location)
                            .font(ZimamType.body)
                            .foregroundStyle(ZimamColor.ink)
                            .textSelection(.enabled)
                    }
                }
                if let notes = trimmed(item.event.notes) {
                    Section("الملاحظات") {
                        Text(notes)
                            .font(ZimamType.body)
                            .foregroundStyle(ZimamColor.ink)
                            .lineSpacing(ZimamType.bodyLineSpacing)
                            .textSelection(.enabled)
                    }
                }
                Section("التقويم") {
                    HStack(spacing: ZimamSpacing.space3) {
                        EventMarker(color: item.color)
                        Text(item.calendarTitle)
                            .font(ZimamType.body)
                            .foregroundStyle(ZimamColor.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
                Section {
                    VStack(spacing: ZimamSpacing.space2) {
                        Button { convert() } label: {
                            Label(converted ? "أُضيفت المهمة" : "تحويل إلى مهمة",
                                  systemImage: converted ? "checkmark.circle" : "plus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.zimamPrimary)
                        .disabled(converted)
                        Button { openInCalendar() } label: {
                            Label("فتح في التقويم", systemImage: "calendar")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.zimamSecondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(footer)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("حدث في التقويم")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .sheet(item: $systemEvent) { wrapped in
            EventKitEventView(event: wrapped.event) { systemEvent = nil }
                .ignoresSafeArea()
        }
        #endif
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 12, minHeight: ZimamSpacing.space8 * 14)
        #endif
    }

    private var footer: String {
        if converted { return "أُضيفت إلى «الوارد» بعنوان الحدث وموعده وملاحظاته. الحدث نفسه باقٍ في التقويم كما هو." }
        if wasConvertedBefore { return "حُوِّل هذا الحدث إلى مهمة من قبل." }
        return "تُضاف مهمة في «الوارد» بعنوان الحدث وموعده ومكانه وملاحظاته، ولا يتغيّر الحدث في التقويم."
    }

    private var refs: CalendarImportRefs { CalendarImportRefs(userId: session.user?.id) }

    private var wasConvertedBefore: Bool {
        refs.tasks[item.event.importKey(timeZone: formatter.timeZone)] != nil
    }

    private func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private func convert() {
        guard !converted, let fields = item.event.taskFields(timeZone: formatter.timeZone) else { return }
        let task = Store(context: context, sync: sync)
            .addTask(title: fields.title, dueDate: fields.dueDate, notes: fields.notes, dueTime: fields.dueTime,
                     startDate: fields.startDate)
        refs.remember(tasks: [item.event.importKey(timeZone: formatter.timeZone): task.id], projects: [:])
        withAnimation(reduceMotion ? nil : .default) { converted = true }
        AccessibilityNotification.Announcement("أُضيفت المهمة «\(fields.title)»").post()
    }

    private func openInCalendar() {
        #if os(iOS)
        if let found = CalendarEvents.shared.ekEvent(for: item.event) {
            systemEvent = SystemEvent(event: found)
            return
        }
        // Not found (deleted meanwhile): Calendar on the event's day.
        if let url = URL(string: "calshow:\(Int(item.event.start.timeIntervalSinceReferenceDate))") { openURL(url) }
        #else
        let calendarApp = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        guard let identifier = item.event.eventId,
              let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") else {
            openURL(calendarApp)
            return
        }
        openURL(url) { accepted in
            if !accepted { openURL(calendarApp) }
        }
        #endif
    }
}

#if os(iOS)
/// An `EKEvent` as a sheet item.
private struct SystemEvent: Identifiable {
    let event: EKEvent
    var id: ObjectIdentifier { ObjectIdentifier(event) }
}

/// Calendar's own view of the event (read only here), with its «تم».
struct EventKitEventView: UIViewControllerRepresentable {
    let event: EKEvent
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = EKEventViewController()
        controller.event = event
        controller.allowsEditing = false
        controller.allowsCalendarPreview = true
        controller.delegate = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, EKEventViewDelegate {
        let onDone: () -> Void

        init(onDone: @escaping () -> Void) {
            self.onDone = onDone
        }

        func eventViewController(_ controller: EKEventViewController, didCompleteWith action: EKEventViewAction) {
            onDone()
        }
    }
}
#endif
