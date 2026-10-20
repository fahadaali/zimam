import EventKit
import SwiftData
import SwiftUI
import ZimamKit
#if os(iOS)
import EventKitUI
import UIKit
#endif

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

    private var footer: String {
        if converted { return "أُضيفت إلى «الوارد» بعنوان الحدث وموعده وملاحظاته. الحدث نفسه باقٍ في التقويم كما هو." }
        if wasConvertedBefore { return "حُوِّل هذا الحدث إلى مهمة من قبل." }
        return "تُضاف مهمة في «الوارد» بعنوان الحدث وموعده ومكانه وملاحظاته، ولا يتغيّر الحدث في التقويم."
    }

    private var refs: CalendarImportRefs { CalendarImportRefs(userId: session.user?.id) }

    private var wasConvertedBefore: Bool {
        refs.tasks[item.event.importKey(timeZone: formatter.timeZone)] != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                CalendarEventHeaderSection(item: item)
                CalendarEventTextSections(location: trimmed(item.event.location), notes: trimmed(item.event.notes))
                CalendarEventCalendarSection(item: item)
                CalendarEventActionsSection(
                    converted: converted,
                    footer: footer,
                    onConvert: { convert() },
                    onOpenInCalendar: { openInCalendar() }
                )
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

    private func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private func convert() {
        guard !converted, let fields = item.event.taskFields(timeZone: formatter.timeZone) else { return }
        let store = Store(context: context, sync: sync)
        let task = store.addTask(title: fields.title, dueDate: fields.dueDate, notes: fields.notes, dueTime: fields.dueTime,
                                 startDate: fields.startDate)
        store.ensureAtTimeReminder(task)
        refs.remember(tasks: [item.event.importKey(timeZone: formatter.timeZone): task.id], projects: [:])
        withAnimation(.zimam(reduceMotion: reduceMotion)) { converted = true }
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

/// The event's title, and when it is in both calendars.
struct CalendarEventHeaderSection: View {
    let item: ShownEvent

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
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
    }
}

/// «المكان» and «الملاحظات», each only when the event has it.
struct CalendarEventTextSections: View {
    let location: String?
    let notes: String?

    var body: some View {
        if let location {
            Section("المكان") {
                Text(location)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
                    .textSelection(.enabled)
            }
        }
        if let notes {
            Section("الملاحظات") {
                Text(notes)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
                    .lineSpacing(ZimamType.bodyLineSpacing)
                    .textSelection(.enabled)
            }
        }
    }
}

/// «التقويم»: the event's calendar with its marker.
struct CalendarEventCalendarSection: View {
    let item: ShownEvent

    var body: some View {
        Section("التقويم") {
            HStack(spacing: ZimamSpacing.space3) {
                EventMarker(color: item.color)
                Text(item.calendarTitle)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// «تحويل إلى مهمة» and «فتح في التقويم», with what converting does.
struct CalendarEventActionsSection: View {
    let converted: Bool
    let footer: String
    let onConvert: () -> Void
    let onOpenInCalendar: () -> Void

    var body: some View {
        Section {
            VStack(spacing: ZimamSpacing.space2) {
                Button(action: onConvert) {
                    Label(converted ? "أُضيفت المهمة" : "تحويل إلى مهمة",
                          systemImage: converted ? "checkmark.circle" : "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.zimamPrimary)
                .disabled(converted)
                Button(action: onOpenInCalendar) {
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
