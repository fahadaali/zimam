import SwiftData
import SwiftUI
import ZimamKit

/// «تذكير بالموقع». A saved place from «أماكني» takes one tap, as in Apple's Reminders; or the
/// user finds a new one with Apple Maps search (names come in Arabic, the app's only localization)
/// or the current location, names it, sets how far around it counts (١٠٠ م to ١ كم) and keeps it
/// in «أماكني» for next time. Then arriving or leaving, and optionally a time: the reminder then
/// fires once, at whichever comes first. Nothing is saved until «إضافة». The place syncs with
/// the reminder; the device watches it (`NotificationScheduler`, `PlaceMonitor`).
/// The search is in PlaceSearchSection.swift, the place rows in PlaceOption.swift, and the
/// current position in CurrentPlaceReader.swift.
struct LocationReminderSheet: View {
    /// Where the place comes from: one tap on a saved place, or a new one from the search.
    enum Source: Equatable {
        case saved(UUID)
        case new(PlaceOption)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Query(filter: #Predicate<PlaceItem> { !$0.pendingDelete }, sort: \PlaceItem.name) private var saved: [PlaceItem]

    /// The place copied into the reminder, and the time that competes with it.
    let onAdd: (ReminderRecord.Location, Date?) -> Void

    @State private var source: Source?
    @State private var name = ""
    @State private var keep = true
    @State private var radius = LocationReminderPlanner.defaultRadius
    @State private var trigger: ReminderRecord.Location.Trigger = .arrive
    @State private var hasTime = false
    @State private var time = Date().addingTimeInterval(3600)

    private var chosenSaved: PlaceItem? {
        guard case .saved(let id) = source else { return nil }
        return saved.first { $0.id == id }
    }

    private var newOption: PlaceOption? {
        guard case .new(let option) = source else { return nil }
        return option
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A saved place already has this name (ignoring diacritics and letter forms).
    private var nameTaken: Bool {
        PlaceNames.isTaken(trimmedName, among: saved.map(\.name))
    }

    private var newPlaceFooter: String {
        if keep && trimmedName.isEmpty { return "اكتب اسماً ليُحفظ في أماكنك، أو أطفئ الحفظ." }
        if keep && nameTaken { return "في أماكنك مكان بهذا الاسم. اختره من الأعلى، أو اختر اسماً آخر." }
        return "يظهر الاسم في التذكير: «\(LocationReminderPlanner.body(placeName: name, trigger: trigger, taskTitle: "المهمة"))»."
    }

    private var canAdd: Bool {
        switch source {
        case nil: false
        case .saved: chosenSaved != nil
        case .new: !keep || (!trimmedName.isEmpty && !nameTaken)
        }
    }

    init(onAdd: @escaping (ReminderRecord.Location, Date?) -> Void) {
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            Form {
                AlwaysLocationSection()
                if !saved.isEmpty {
                    LocationSavedPlacesSection(saved: saved, source: $source)
                }
                PlaceSearchSection(title: saved.isEmpty ? "المكان" : "مكان جديد", selection: newOption) { choose($0) }
                if let option = newOption {
                    LocationNewPlaceSection(option: option, name: $name, keep: $keep, radius: $radius, footer: newPlaceFooter)
                }
                if source != nil {
                    LocationTriggerSection(trigger: $trigger, hasTime: hasTime)
                    LocationTimeSection(hasTime: $hasTime, time: $time, trigger: trigger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("تذكير بالموقع")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إضافة", action: add)
                        .disabled(!canAdd)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 14, minHeight: ZimamSpacing.space8 * 18)
        #endif
    }

    // MARK: Actions

    private func choose(_ option: PlaceOption) {
        // Keeps a name the user typed; replaces the previous place's own name.
        let previousName = newOption.map { $0.isCurrentLocation ? "" : $0.name } ?? ""
        if trimmedName.isEmpty || trimmedName == previousName {
            name = option.isCurrentLocation ? "" : option.name
        }
        source = .new(option)
    }

    private func add() {
        let place: ReminderRecord.Location
        switch source {
        case .saved?:
            guard let chosen = chosenSaved else { return }
            place = ReminderRecord.Location(place: chosen.record, trigger: trigger)
        case .new(let option)?:
            if keep {
                let item = Store(context: context, sync: sync)
                    .addPlace(name: trimmedName, latitude: option.latitude, longitude: option.longitude, radius: radius)
                place = ReminderRecord.Location(place: item.record, trigger: trigger)
            } else {
                place = ReminderRecord.Location(
                    latitude: option.latitude,
                    longitude: option.longitude,
                    radius: min(max(radius, LocationReminderPlanner.serverRadiusRange.lowerBound),
                                LocationReminderPlanner.serverRadiusRange.upperBound),
                    name: trimmedName.isEmpty ? nil : String(trimmedName.prefix(200)),
                    trigger: trigger
                )
            }
        case nil:
            return
        }
        onAdd(place, hasTime ? time : nil)
        dismiss()
    }
}

// MARK: Saved places

/// «أماكني» as chips: one tap chooses a saved place.
struct LocationSavedPlacesSection: View {
    let saved: [PlaceItem]
    @Binding var source: LocationReminderSheet.Source?

    var body: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: ZimamSpacing.space2) {
                    ForEach(saved) { place in
                        Button {
                            source = .saved(place.id)
                        } label: {
                            PlaceChip(name: place.name, isSelected: source == .saved(place.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(place.name)
                    }
                }
                .padding(.vertical, ZimamSpacing.space1)
            }
            .scrollIndicators(.hidden)
        } header: {
            Text("أماكني")
        }
    }
}

// MARK: A new place

/// The place found by the search: its name, whether to keep it, and its radius on a map.
struct LocationNewPlaceSection: View {
    let option: PlaceOption
    @Binding var name: String
    @Binding var keep: Bool
    @Binding var radius: Double
    let footer: String

    var body: some View {
        Section {
            TextField("اسم المكان، مثل البيت أو العمل", text: $name)
            Toggle("حفظ في أماكني", isOn: $keep)
                .frame(minHeight: ZimamSpacing.space11)
            PlacePreview(place: option, radius: radius)
            RadiusSlider(radius: $radius)
        } header: {
            Text("المكان المختار")
        } footer: {
            Text(footer)
        }
    }
}

// MARK: Arriving or leaving, and the time

/// Arriving or leaving.
struct LocationTriggerSection: View {
    @Binding var trigger: ReminderRecord.Location.Trigger
    let hasTime: Bool

    var body: some View {
        Section {
            Picker("التذكير", selection: $trigger) {
                Text(LocationReminderPlanner.triggerText(.arrive)).tag(ReminderRecord.Location.Trigger.arrive)
                Text(LocationReminderPlanner.triggerText(.leave)).tag(ReminderRecord.Location.Trigger.leave)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: ZimamSpacing.space11)
        } footer: {
            #if os(iOS)
            if !hasTime {
                Text("يصلك التذكير كلما وصلت أو غادرت حتى تنجز المهمة.")
            }
            #else
            Text("تذكيرات الموقع تصل على الآيفون والآيباد، ولا تعمل على الماك.")
            #endif
        }
    }
}

/// «أو في وقت محدد»: a time that competes with the place.
struct LocationTimeSection: View {
    @Binding var hasTime: Bool
    @Binding var time: Date
    let trigger: ReminderRecord.Location.Trigger

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Section {
            Toggle("أو في وقت محدد", isOn: $hasTime)
                .frame(minHeight: ZimamSpacing.space11)
            if hasTime {
                DatePicker("الوقت", selection: $time, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                Text(formatter.dual(time, withYear: true))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        } footer: {
            if hasTime {
                Text("يصلك مرة واحدة: عند \(trigger == .arrive ? "الوصول" : "المغادرة") أو في الوقت، أيهما أسبق.")
            }
        }
    }
}
