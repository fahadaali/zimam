import SwiftUI
import ZimamKit

/// «سيري»: what to say to Siri, and «استقبال تذكيرات سيري», which brings «ذكرني …» said without
/// naming Zimam over from Apple Reminders (`ReminderBridge`).
struct SiriSettingsView: View {
    @State private var lists: [(id: String, title: String, isDefault: Bool)] = []
    @State private var askedAndDenied = false

    private var bridge: ReminderBridge { ReminderBridge.shared }

    var body: some View {
        Form {
            Section {
                Toggle("استقبال تذكيرات سيري", isOn: isOnBinding)
                    .frame(minHeight: ZimamSpacing.space11)
                if bridge.isOn, !lists.isEmpty {
                    Picker("القائمة", selection: listBinding) {
                        ForEach(lists, id: \.id) { list in
                            Text(list.isDefault ? "\(list.title) (الافتراضية)" : list.title).tag(Optional(list.id))
                        }
                    }
                    Button("نقل الآن", systemImage: "arrow.down.circle") {
                        Task { await bridge.run() }
                    }
                    .disabled(bridge.isRunning)
                    .frame(minHeight: ZimamSpacing.space11)
                    if let result = bridge.lastResult {
                        Text(result)
                            .font(ZimamType.callout)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                }
                if askedAndDenied || bridge.isDenied, let url = LocationProvider.systemSettingsURL {
                    Link(destination: url) {
                        Label("السماح بالتذكيرات من إعدادات النظام", systemImage: "gear")
                    }
                    .frame(minHeight: ZimamSpacing.space11)
                }
            } header: {
                Text("ذكرني دون ذكر زمام")
            } footer: {
                Text("لا تسمح أبل بأن يكون غير «التذكيرات» تطبيق سيري للتذكير. فإذا قلت «ذكرني أتصل بأبي بكرة بعد العصر» حفظه سيري في «التذكيرات»، ونقله زمام إلى مهامك بموعده ثم حذفه منها. يُنقل حين تفتح زمام، وفي الخلفية حين يوقظه النظام، فقد يتأخر إن بقي مغلقاً، ويبقى تنبيه «التذكيرات» حتى يُنقل. التذكير المرتبط بمكان يبقى في «التذكيرات».")
            }

            Section {
                phrase("ذكرني في زمام", "ثم قل المهمة وموعدها كما تقولها لشخص.")
                phrase("ذكرني في زمام بعد العصر", "أو «قبل المغرب»، ثم المهمة. «قبل» تذكّرك قبل الأذان بربع ساعة.")
                phrase("ذكرني في زمام إذا وصلت البيت", "لمكان من «أماكني».")
                phrase("أضف مهمة في زمام", "بعنوان وتاريخ وصلاة.")
                phrase("ما مهام اليوم في زمام", "يقرأ مهامك اليوم.")
                phrase("أنجز مهمة في زمام", "يسألك أي مهمة.")
            } header: {
                Text("عبارات زمام لسيري")
            } footer: {
                Text("يفهم زمام «قبل» و«بعد» الصلاة، و«بكرة» و«الخميس»، و«الساعة ٥ العصر»، و«بعد ساعتين»، و«الليلة»، حتى دون اتصال.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle("سيري")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { lists = bridge.lists() }
    }

    private func phrase(_ words: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Text("«\(words)»")
                .font(ZimamType.body)
                .foregroundStyle(ZimamColor.ink)
            Text(detail)
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
        }
        .frame(minHeight: ZimamSpacing.space11)
        .accessibilityElement(children: .combine)
    }

    private var isOnBinding: Binding<Bool> {
        Binding(
            get: { bridge.isOn },
            set: { on in
                guard on else {
                    bridge.isOn = false
                    return
                }
                Task {
                    if await bridge.requestAccess() {
                        lists = bridge.lists()
                        bridge.isOn = true
                    } else {
                        askedAndDenied = true
                    }
                }
            }
        )
    }

    private var listBinding: Binding<String?> {
        Binding(
            get: { bridge.listId ?? lists.first(where: \.isDefault)?.id },
            set: { bridge.listId = $0 }
        )
    }
}
