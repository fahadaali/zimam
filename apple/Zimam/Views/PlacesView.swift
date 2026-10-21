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

    @State private var route: PlaceSheet?
    @State private var deleting: PlaceItem?

    private var store: Store { Store(context: context, sync: sync) }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var deleteTitle: String {
        deleting.map { "حذف «\($0.name)»؟" } ?? ""
    }

    var body: some View {
        Form {
            AlwaysLocationSection()
            PlacesListSection(
                places: places,
                onEdit: { place in route = .editing(place) },
                onDelete: { place in delete(place) },
                onAdd: { route = .adding }
            )
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle("أماكني")
        // The sheet closes as it saves, so the list confirms a new place.
        .sensoryFeedback(.success, trigger: places.count) { old, new in new > old }
        .sheet(item: $route) { route in
            PlaceEditorSheet(place: route.place)
        }
        .confirmationDialog(deleteTitle, isPresented: deletingBinding, titleVisibility: .visible, presenting: deleting) { place in
            Button("حذف", role: .destructive) { store.deletePlace(place) }
        } message: { place in
            Text(deleteMessage(place))
        }
    }

    /// Asks first only when reminders use the place; otherwise it simply goes.
    private func delete(_ place: PlaceItem) {
        if store.reminders(at: place.id).isEmpty {
            store.deletePlace(place)
        } else {
            deleting = place
        }
    }

    private func deleteMessage(_ place: PlaceItem) -> String {
        let count = store.reminders(at: place.id).count.formatted(.number.locale(formatter.locale))
        return "تبقى تذكيراته (\(count)) في مكانه الأخير، ولا يُحذف منها شيء."
    }
}

/// The sheet «أماكني» shows: a new place, or a saved one to edit.
private enum PlaceSheet: Identifiable {
    case adding
    case editing(PlaceItem)

    var id: String {
        switch self {
        case .adding: "adding"
        case .editing(let place): place.id.uuidString
        }
    }

    /// The place being edited; `nil` adds one.
    var place: PlaceItem? {
        switch self {
        case .adding: nil
        case .editing(let place): place
        }
    }
}

/// The saved places, each opening its editor, and «إضافة مكان».
private struct PlacesListSection: View {
    let places: [PlaceItem]
    let onEdit: (PlaceItem) -> Void
    let onDelete: (PlaceItem) -> Void
    let onAdd: () -> Void

    var body: some View {
        Section {
            ForEach(places) { place in
                Button { onEdit(place) } label: {
                    PlaceRow(place: place)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("حذف", systemImage: "trash", role: .destructive) { onDelete(place) }
                }
                .contextMenu {
                    Button("تعديل", systemImage: "pencil") { onEdit(place) }
                    Button("حذف", systemImage: "trash", role: .destructive) { onDelete(place) }
                }
            }
            Button("إضافة مكان", systemImage: "plus", action: onAdd)
                .frame(minHeight: ZimamSpacing.space11)
        } footer: {
            Text("سمِّ أماكنك مرة، ثم اربط بها تذكيرات مهامك: «ذكّرني إذا وصلت البيت». تتزامن مع حسابك، ويعرف أسماءها سيري وكلود وChatGPT.")
        }
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

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Shown as the user types, not after «حفظ».
    private var nameProblem: String? {
        if trimmed.isEmpty { return "اكتب اسماً تعرفه به، مثل «البيت»." }
        if PlaceNames.isTaken(trimmed, among: places.map(\.name), except: place?.name) {
            return "في أماكنك مكان بهذا الاسم."
        }
        return nil
    }

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
                PlaceNameSection(name: $name, problem: nameProblem)
                PlaceSearchSection(title: place == nil ? "المكان" : "نقل المكان", selection: option) { choose($0) }
                if let option {
                    PlaceAreaSection(option: option, radius: $radius)
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

/// «الاسم», with what is wrong with it while it cannot be saved.
private struct PlaceNameSection: View {
    @Binding var name: String
    let problem: String?

    var body: some View {
        Section {
            TextField(hint: "اسم المكان، مثل البيت أو العمل", text: $name)
                .labelsHidden()
        } header: {
            Text("الاسم")
        } footer: {
            if let problem { Text(problem) }
        }
    }
}

/// The chosen place on a map, and how far around it counts.
private struct PlaceAreaSection: View {
    let option: PlaceOption
    @Binding var radius: Double

    var body: some View {
        Section {
            PlacePreview(place: option, radius: radius)
            RadiusSlider(radius: $radius)
        } footer: {
            Text("النطاق الأوسع أدق في الأماكن الكبيرة، والأضيق قد يتأخر فيه التذكير.")
        }
    }
}
