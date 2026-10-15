import SwiftData
import SwiftUI
import ZimamKit

/// «تقويم أبل»: asks for access, lets the user choose calendars and how far ahead, and imports their
/// events as tasks on this device.
struct CalendarImportView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var importer = CalendarImporter()

    init() {}

    var body: some View {
        Form {
            Section {
                Text("تُقرأ أحداث التقاويم التي تختارها من تقويم أبل على هذا الجهاز، من اليوم إلى المدة التي تحددها، فيصير كل تقويم مشروعاً وكل حدث مهمة. لا يُغيَّر شيء في التقويم نفسه.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            CalendarAccessSection(access: importer.access,
                                  purpose: "يطلب النظام إذنك مرة واحدة. يقرأ زمام الأحداث عند الاستيراد، ولا يغيّرها.") {
                Task { await importer.requestAccess() }
            }
            if importer.access == .granted {
                calendarsSection
                windowSection
                actionSection
            }
            if let message = importer.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ZimamColor.priorityHigh)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle("تقويم أبل")
        .task { importer.refresh() }
        // Back from Settings, where the permission may have changed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { importer.refresh() }
        }
    }

    private var calendarsSection: some View {
        Section {
            if importer.calendars.isEmpty {
                Text("لا تقاويم على هذا الجهاز.")
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            ForEach(importer.calendars) { calendar in
                Toggle(isOn: selection(for: calendar.id)) {
                    CalendarChoiceLabel(calendar: calendar, color: CalendarEvents.shared.color(for: calendar.id))
                }
                .frame(minHeight: ZimamSpacing.space11)
            }
        } header: {
            Text("التقاويم")
        } footer: {
            Text("كل تقويم يصير مشروعاً، ويُنقل العنوان والمكان والملاحظات والموعد ووقته. الحدث الممتد أياماً يصير مهمة من أول يوم إلى آخره، والمتكرر مهمة متكررة إن كان تكراره مما يدعمه زمام، وإلا فكل موعد منه مهمة.")
        }
    }

    private var windowSection: some View {
        Section {
            Picker("المدة", selection: $importer.months) {
                ForEach(CalendarImporter.windows, id: \.self) { months in
                    Text(label(months)).tag(months)
                }
            }
            .frame(minHeight: ZimamSpacing.space11)
        } header: {
            Text("من اليوم إلى")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await importer.importSelected(context: context, sync: sync, userId: session.user?.id) }
            } label: {
                HStack(spacing: ZimamSpacing.space2) {
                    if importer.isWorking { ProgressView() }
                    Text(importer.isWorking ? "جارٍ الاستيراد…" : "استيراد الأحداث")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.zimamPrimary)
            .disabled(importer.isWorking || importer.selected.isEmpty)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if let result = importer.resultMessage {
                Label(result, systemImage: "checkmark.circle")
                    .foregroundStyle(ZimamColor.success)
            }
        } footer: {
            Text("إعادة الاستيراد تضيف الجديد فقط، ولا تكرر ما استُورد من قبل أو حُوِّل إلى مهمة.")
        }
        .onChange(of: importer.resultMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    /// «شهر واحد»، «٣ أشهر»، «٦ أشهر»، «سنة».
    private func label(_ months: Int) -> String {
        switch months {
        case 1: return "شهر واحد"
        case 12: return "سنة"
        default: return "\(months.formatted(.number.locale(ZimamLocale.current))) أشهر"
        }
    }

    private func selection(for id: String) -> Binding<Bool> {
        Binding(
            get: { importer.selected.contains(id) },
            set: { isOn in
                if isOn { importer.selected.insert(id) } else { importer.selected.remove(id) }
            }
        )
    }
}
