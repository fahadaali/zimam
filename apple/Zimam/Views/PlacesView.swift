import SwiftData
import SwiftUI
import ZimamKit

/// «أماكني»: places the user names once («البيت», «العمل», «الاستراحة») and reuses for location
/// reminders, here, with Siri («ذكّرني في زمام إذا وصلت البيت…») and with Claude and ChatGPT.
/// They sync with the account. Moving or resizing a place moves every reminder there; deleting
/// one leaves its reminders where it was.
struct PlacesView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dateFormatterZimam) private var formatter
    @Query(filter: #Predicate<PlaceItem> { !$0.pendingDelete }, sort: \PlaceItem.name) private var places: [PlaceItem]

    @State private var adding = false
    @State private var editing: PlaceItem?
    @State private var deleting: PlaceItem?

    var body: some View {
        Form {
            AlwaysLocationSection()
            Section {
                ForEach(places) { place in
                    Button { editing = place } label: {
                        PlaceRow(place: place)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("حذف", systemImage: "trash", role: .destructive) { delete(place) }
                    }
                    .contextMenu {
                        Button("تعديل", systemImage: "pencil") { editing = place }
                        Button("حذف", systemImage: "trash", role: .destructive) { delete(place) }
                    }
                }
                Button("إضافة مكان", systemImage: "plus") { adding = true }
                    .frame(minHeight: ZimamSpacing.space11)
            } footer: {
                Text("سمِّ أماكنك مرة، ثم اربط بها تذكيرات مهامك: «ذكّرني إذا وصلت البيت». تتزامن مع حسابك، ويعرف أسماءها سيري وكلود وChatGPT.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle("أماكني")
        // The sheet closes as it saves, so the list confirms a new place.
        .sensoryFeedback(.success, trigger: places.count) { old, new in new > old }
        .sheet(isPresented: $adding) { PlaceEditorSheet(place: nil) }
        .sheet(item: $editing) { PlaceEditorSheet(place: $0) }
        .confirmationDialog(deleteTitle, isPresented: deletingBinding, titleVisibility: .visible, presenting: deleting) { place in
            Button("حذف", role: .destructive) { store.deletePlace(place) }
        } message: { place in
            Text(deleteMessage(place))
        }
    }

    private var store: Store { Store(context: context, sync: sync) }

    /// Asks first only when reminders use the place; otherwise it simply goes.
    private func delete(_ place: PlaceItem) {
        if store.reminders(at: place.id).isEmpty {
            store.deletePlace(place)
        } else {
            deleting = place
        }
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var deleteTitle: String {
        deleting.map { "حذف «\($0.name)»؟" } ?? ""
    }

    private func deleteMessage(_ place: PlaceItem) -> String {
        let count = store.reminders(at: place.id).count.formatted(.number.locale(formatter.locale))
        return "تبقى تذكيراته (\(count)) في مكانه الأخير، ولا يُحذف منها شيء."
    }
}

private struct PlaceRow: View {
    let place: PlaceItem

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            Image(systemName: "mappin")
                .foregroundStyle(ZimamColor.inkMuted)
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Text(place.name)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
                Text("النطاق \(LocationReminderPlanner.radiusText(place.radius, locale: formatter.locale))")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward")
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkFaint)
                .accessibilityHidden(true)
        }
        .frame(minHeight: ZimamSpacing.space11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("تعديل المكان")
    }
}

/// Adds a place, or renames, moves or resizes one. Nothing changes until «حفظ».
struct PlaceEditorSheet: View {
    let place: PlaceItem?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Query(filter: #Predicate<PlaceItem> { !$0.pendingDelete }) private var places: [PlaceItem]

    @State private var option: PlaceOption?
    @State private var name: String
    @State private var radius: Double

    init(place: PlaceItem?) {
        self.place = place
        _name = State(initialValue: place?.name ?? "")
        _radius = State(initialValue: place.map { LocationReminderPlanner.sliderRadius($0.radius) } ?? LocationReminderPlanner.defaultRadius)
        _option = State(initialValue: place.map {
            PlaceOption(name: $0.name, detail: nil, latitude: $0.latitude, longitude: $0.longitude)
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                AlwaysLocationSection()
                Section {
                    TextField("اسم المكان، مثل البيت أو العمل", text: $name)
                } header: {
                    Text("الاسم")
                } footer: {
                    if let problem = nameProblem { Text(problem) }
                }
                PlaceSearchSection(title: place == nil ? "المكان" : "نقل المكان", selection: option) { choose($0) }
                if let option {
                    Section {
                        PlacePreview(place: option, radius: radius)
                        RadiusSlider(radius: $radius)
                    } footer: {
                        Text("النطاق الأوسع أدق في الأماكن الكبيرة، والأضيق قد يتأخر فيه التذكير.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle(place == nil ? "مكان جديد" : "تعديل المكان")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ", action: save)
                        .disabled(option == nil || nameProblem != nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 14, minHeight: ZimamSpacing.space8 * 18)
        #endif
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Shown as the user types, not after «حفظ».
    private var nameProblem: String? {
        if trimmed.isEmpty { return "اكتب اسماً تعرفه به، مثل «البيت»." }
        if PlaceNames.isTaken(trimmed, among: places.map(\.name), except: place?.name) {
            return "في أماكنك مكان بهذا الاسم."
        }
        return nil
    }

    private func choose(_ chosen: PlaceOption) {
        // A searched place lends its name only while the field is empty.
        if trimmed.isEmpty && !chosen.isCurrentLocation { name = chosen.name }
        option = chosen
    }

    private func save() {
        guard let option, nameProblem == nil else { return }
        let store = Store(context: context, sync: sync)
        if let place {
            store.updatePlace(place, name: trimmed, latitude: option.latitude, longitude: option.longitude, radius: radius)
        } else {
            store.addPlace(name: trimmed, latitude: option.latitude, longitude: option.longitude, radius: radius)
        }
        dismiss()
    }
}

/// Why «دائماً», and the way there. Location reminders work with location while using the app,
/// but only «دائماً» lets a place and a time on one reminder take each other back, and keeps
/// watching when many places are saved. Asked here, when the user is adding a place or a
/// reminder, never at launch; turning it down changes nothing else.
struct AlwaysLocationSection: View {
    @Environment(LocationProvider.self) private var location

    var body: some View {
        #if os(iOS)
        if !location.canMonitorPlaces {
            Section {
                VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                    Label("اسمح بالموقع «دائماً»", systemImage: "location.circle")
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.ink)
                    Text("ليذكّرك زمام حين تصل إلى أماكنك أو تغادرها والتطبيق مغلق، وليصلك التذكير المرتبط بمكان ووقت مرة واحدة عند أيهما أسبق. يراقب جهازك أماكنك، ولا يُرسل موقعك إلى زمام.")
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, ZimamSpacing.space1)
                if location.canAskForAlways {
                    Button("السماح بالموقع دائماً", systemImage: "location") { location.requestAlwaysAuthorization() }
                        .frame(minHeight: ZimamSpacing.space11)
                } else if let url = LocationProvider.systemSettingsURL {
                    Link(destination: url) {
                        Label(settingsLabel, systemImage: "gear")
                    }
                    .frame(minHeight: ZimamSpacing.space11)
                }
            } footer: {
                if location.needsAlways {
                    Text("تذكيرات الأماكن تعمل الآن أيضاً، لكن قد يصلك التذكيران معاً: عند المكان وفي الوقت.")
                }
            }
        }
        #else
        Section {
            Text("تذكيرات الأماكن تصل على الآيفون والآيباد. الأماكن التي تحفظها هنا تظهر فيهما.")
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.inkMuted)
        }
        #endif
    }

    private var settingsLabel: String {
        if location.isDenied { return "السماح بالموقع من الإعدادات" }
        if !location.isPrecise { return "تفعيل «الموقع الدقيق» من الإعدادات" }
        return "اختيار «دائماً» من الإعدادات"
    }
}
