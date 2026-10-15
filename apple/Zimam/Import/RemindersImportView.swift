import SwiftData
import SwiftUI
import ZimamKit
#if canImport(UIKit)
import UIKit
#endif

/// «تذكيرات أبل»: asks for access, lets the user choose lists, and imports them on this device.
struct RemindersImportView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var importer = RemindersImporter()

    init() {}

    var body: some View {
        Form {
            Section {
                Text(ImportText.howTo(source: AppleRemindersImport.sourceId))
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            switch importer.access {
            case .notDetermined:
                Section {
                    Button("السماح بالوصول إلى التذكيرات", systemImage: "checklist") {
                        Task { await importer.requestAccess() }
                    }
                    .frame(minHeight: ZimamSpacing.space11)
                } footer: {
                    Text("يطلب النظام إذنك مرة واحدة. يقرأ زمام التذكيرات عند الاستيراد فقط، ولا يغيّرها.")
                }
            case .granted:
                listsSection
                actionSection
            case .writeOnly, .denied:
                deniedSection(writeOnly: importer.access == .writeOnly)
            case .restricted:
                Section {
                    Text("الوصول إلى التذكيرات مقيّد على هذا الجهاز، فلا يمكن الاستيراد منها.")
                        .foregroundStyle(ZimamColor.inkMuted)
                }
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
        .navigationTitle("تذكيرات أبل")
        .task { importer.refresh() }
        // Back from Settings, where the permission may have changed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { importer.refresh() }
        }
    }

    private var listsSection: some View {
        Section {
            if importer.lists.isEmpty {
                Text("لا قوائم في التذكيرات على هذا الجهاز.")
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            ForEach(importer.lists) { list in
                Toggle(isOn: selection(for: list.id)) {
                    Text(list.title)
                }
                .frame(minHeight: ZimamSpacing.space11)
            }
        } header: {
            Text("القوائم")
        } footer: {
            Text("كل قائمة تصير مشروعاً، ويُنقل العنوان والملاحظات والموعد ووقته والأولوية والإنجاز والتكرار والتنبيهات القادمة.")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await importer.importSelected(context: context, sync: sync, userId: session.user?.id) }
            } label: {
                HStack(spacing: ZimamSpacing.space2) {
                    if importer.isWorking { ProgressView() }
                    Text(importer.isWorking ? "جارٍ الاستيراد…" : "استيراد القوائم المختارة")
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
            Text("إعادة الاستيراد تضيف الجديد فقط، ولا تكرر ما استُورد من قبل.")
        }
        .onChange(of: importer.resultMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private func deniedSection(writeOnly: Bool) -> some View {
        Section {
            Text(writeOnly
                 ? "لزمام إذن الإضافة إلى التذكيرات فقط. اسمح له بالوصول الكامل من إعدادات النظام ليقرأها."
                 : "لم يُسمح لزمام بقراءة التذكيرات. اسمح له من إعدادات النظام ثم ارجع إلى هنا.")
            if let url = Self.settingsURL {
                Button("فتح إعدادات النظام", systemImage: "gear") { openURL(url) }
                    .frame(minHeight: ZimamSpacing.space11)
            }
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

    #if os(iOS)
    private static var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
    #else
    private static var settingsURL: URL? { URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") }
    #endif
}
