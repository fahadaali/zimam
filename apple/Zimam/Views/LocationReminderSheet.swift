import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import ZimamKit

/// «تذكير بالموقع». A saved place from «أماكني» takes one tap, as in Apple's Reminders; or the
/// user finds a new one with Apple Maps search (names come in Arabic, the app's only localization)
/// or the current location, names it, sets how far around it counts (١٠٠ م to ١ كم) and keeps it
/// in «أماكني» for next time. Then arriving or leaving, and optionally a time: the reminder then
/// fires once, at whichever comes first. Nothing is saved until «إضافة». The place syncs with
/// the reminder; the device watches it (`NotificationScheduler`, `PlaceMonitor`).
struct LocationReminderSheet: View {
    /// The place copied into the reminder, and the time that competes with it.
    let onAdd: (ReminderRecord.Location, Date?) -> Void

    /// Where the place comes from: one tap on a saved place, or a new one from the search.
    enum Source: Equatable {
        case saved(UUID)
        case new(PlaceOption)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Query(filter: #Predicate<PlaceItem> { !$0.pendingDelete }, sort: \PlaceItem.name) private var saved: [PlaceItem]

    @State private var source: Source?
    @State private var name = ""
    @State private var keep = true
    @State private var radius = LocationReminderPlanner.defaultRadius
    @State private var trigger: ReminderRecord.Location.Trigger = .arrive
    @State private var hasTime = false
    @State private var time = Date().addingTimeInterval(3600)

    init(onAdd: @escaping (ReminderRecord.Location, Date?) -> Void) {
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            Form {
                AlwaysLocationSection()
                if !saved.isEmpty { savedSection }
                PlaceSearchSection(title: saved.isEmpty ? "المكان" : "مكان جديد", selection: newOption) { choose($0) }
                if case .new(let option) = source {
                    newPlaceSection(option)
                }
                if source != nil {
                    triggerSection
                    timeSection
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

    // MARK: Saved places

    private var savedSection: some View {
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

    private var chosenSaved: PlaceItem? {
        guard case .saved(let id) = source else { return nil }
        return saved.first { $0.id == id }
    }

    private var newOption: PlaceOption? {
        guard case .new(let option) = source else { return nil }
        return option
    }

    // MARK: A new place

    private func newPlaceSection(_ option: PlaceOption) -> some View {
        Section {
            TextField("اسم المكان، مثل البيت أو العمل", text: $name)
            Toggle("حفظ في أماكني", isOn: $keep)
                .frame(minHeight: ZimamSpacing.space11)
            PlacePreview(place: option, radius: radius)
            RadiusSlider(radius: $radius)
        } header: {
            Text("المكان المختار")
        } footer: {
            Text(newPlaceFooter)
        }
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

    // MARK: Arriving or leaving, and the time

    private var triggerSection: some View {
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

    private var timeSection: some View {
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

    // MARK: Actions

    private var canAdd: Bool {
        switch source {
        case nil: false
        case .saved: chosenSaved != nil
        case .new: !keep || (!trimmedName.isEmpty && !nameTaken)
        }
    }

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

// MARK: Finding a place

/// Apple Maps search near the user's area, and «استعمال موقعي الحالي». Shared by the reminder
/// sheet and «أماكني».
struct PlaceSearchSection: View {
    let title: String
    let selection: PlaceOption?
    let onChoose: (PlaceOption) -> Void

    enum SearchPhase: Equatable { case idle, searching, empty, failed }

    @Environment(LocationProvider.self) private var location
    @State private var reader = CurrentPlaceReader()
    @State private var query = ""
    @State private var results: [PlaceOption] = []
    @State private var phase: SearchPhase = .idle

    /// How far around the user's area the search looks first.
    private static let searchSpanMeters: CLLocationDistance = 50_000
    private static let maxResults = 8

    var body: some View {
        Section {
            TextField("ابحث عن مكان أو عنوان", text: $query)
                .autocorrectionDisabled()
            Button("استعمال موقعي الحالي", systemImage: "location") { reader.read() }
                .disabled(reader.isReading)
                .frame(minHeight: ZimamSpacing.space11)
            if reader.isReading {
                ProgressView("جارٍ تحديد موقعك…")
                    .font(ZimamType.callout)
                    .frame(minHeight: ZimamSpacing.space11)
            }
            if let message = reader.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.priorityHigh)
            }
            if reader.isDenied, let url = LocationProvider.systemSettingsURL {
                Link(destination: url) {
                    Label("فتح إعدادات الموقع", systemImage: "gear")
                }
                .frame(minHeight: ZimamSpacing.space11)
            }

            switch phase {
            case .searching:
                ProgressView("جارٍ البحث…")
                    .font(ZimamType.callout)
                    .frame(minHeight: ZimamSpacing.space11)
            case .empty:
                Text("لا نتائج. جرّب اسماً آخر أو عنواناً.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            case .failed:
                Text("تعذّر البحث. تحقّق من اتصالك بالإنترنت وحاول مرة أخرى.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            case .idle:
                EmptyView()
            }

            ForEach(results) { option in
                Button { onChoose(option) } label: {
                    PlaceOptionRow(option: option, isSelected: option == selection)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(title)
        }
        .task(id: query) { await search(query) }
        .onAppear {
            reader.onPlace = { latitude, longitude in
                onChoose(PlaceOption(name: "موقعي الحالي", detail: nil, latitude: latitude, longitude: longitude,
                                     isCurrentLocation: true))
            }
        }
        // The closure holds this view, whose state holds the reader: let go on close.
        .onDisappear { reader.onPlace = nil }
    }

    /// Searches Apple Maps a moment after the user stops typing, near their area when known.
    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            phase = .idle
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        phase = .searching

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.pointOfInterest, .address]
        if let near = reader.coordinate ?? location.coordinate.map({ ($0.latitude, $0.longitude) }) {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.0, longitude: near.1),
                latitudinalMeters: Self.searchSpanMeters,
                longitudinalMeters: Self.searchSpanMeters
            )
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            results = response.mapItems.prefix(Self.maxResults).map(PlaceOption.init(item:))
            phase = results.isEmpty ? .empty : .idle
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            phase = (error as? MKError)?.code == .placemarkNotFound ? .empty : .failed
        }
    }
}

/// How far around a place counts as being there, ١٠٠ م to ١ كم. The circle on the map above it
/// follows the slider as it moves.
struct RadiusSlider: View {
    @Binding var radius: Double

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            HStack(spacing: ZimamSpacing.space2) {
                Text("نطاق المكان")
                Spacer(minLength: ZimamSpacing.space2)
                Text(text(radius))
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            Slider(value: $radius, in: LocationReminderPlanner.radiusRange, step: LocationReminderPlanner.radiusStep) {
                Text("نطاق المكان")
            } minimumValueLabel: {
                Text(text(LocationReminderPlanner.radiusRange.lowerBound))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            } maximumValueLabel: {
                Text(text(LocationReminderPlanner.radiusRange.upperBound))
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            .frame(minHeight: ZimamSpacing.space11)
            .accessibilityValue(text(radius))
        }
        .padding(.vertical, ZimamSpacing.space1)
    }

    private func text(_ meters: Double) -> String {
        LocationReminderPlanner.radiusText(meters, locale: formatter.locale)
    }
}

/// Saved place names compare as the search does: «البيت» and «البَيت» are the same place.
enum PlaceNames {
    static func isTaken(_ name: String, among names: [String], except current: String? = nil) -> Bool {
        let key = fold(name)
        guard !key.isEmpty else { return false }
        return names.contains { fold($0) == key && $0 != current }
    }

    private static func fold(_ name: String) -> String {
        ArabicSearch.fold(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: Place rows

/// A place from the search, or the current location.
struct PlaceOption: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let detail: String?
    let latitude: Double
    let longitude: Double
    var isCurrentLocation = false

    init(name: String, detail: String?, latitude: Double, longitude: Double, isCurrentLocation: Bool = false) {
        self.name = name
        self.detail = detail
        self.latitude = latitude
        self.longitude = longitude
        self.isCurrentLocation = isCurrentLocation
    }

    init(item: MKMapItem) {
        let placemark = item.placemark
        // Street, district and city, as Apple Maps gives them (in Arabic where it has the names).
        var parts: [String] = []
        for part in [placemark.thoroughfare, placemark.subLocality, placemark.locality] {
            if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
        }
        let title = item.name ?? parts.first ?? "مكان على الخريطة"
        let address = parts.filter { $0 != title }.joined(separator: "، ")
        self.init(name: title, detail: address.isEmpty ? nil : address,
                  latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude)
    }
}

struct PlaceOptionRow: View {
    let option: PlaceOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                Text(option.name)
                    .font(ZimamType.body)
                    .foregroundStyle(ZimamColor.ink)
                if let detail = option.detail {
                    Text(detail)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(ZimamColor.brand)
            }
        }
        .frame(minHeight: ZimamSpacing.space11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The place and its circle on a still map, so the radius reads at a glance.
struct PlacePreview: View {
    let place: PlaceOption
    let radius: Double

    var body: some View {
        let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        // Three times the radius on each side keeps the whole circle in view.
        let span = radius * 3
        let region = MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span)
        Map(position: .constant(.region(region)), interactionModes: []) {
            Marker(place.name, coordinate: center)
                .tint(ZimamColor.brand)
            MapCircle(center: center, radius: radius)
                .foregroundStyle(ZimamColor.brandSoft.opacity(0.5))
                .stroke(ZimamColor.brand, lineWidth: ZimamLayout.focusRingWidth)
        }
        .frame(height: ZimamSpacing.space11 * 4)
        .clipShape(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
        .padding(.vertical, ZimamSpacing.space1)
        .accessibilityHidden(true)
    }
}

// MARK: Current location

/// Reads the current position once, precisely, for a location reminder's place. Kept apart from
/// `LocationProvider`, whose city-level reading sets the place for prayer times: choosing a place
/// for a reminder must not move the prayer times. Asks for location while using the app the
/// first time; the reading stops at the first fix within `goodAccuracy`, or at the timeout with
/// the best one so far.
@MainActor
@Observable
final class CurrentPlaceReader {
    private(set) var isReading = false
    private(set) var errorMessage: String?
    private(set) var isDenied = false
    /// The last position read, to search near it.
    private(set) var coordinate: (Double, Double)?
    @ObservationIgnored var onPlace: (@MainActor (Double, Double) -> Void)?

    private let manager = CLLocationManager()
    private let delegate = PlaceReaderDelegate()
    @ObservationIgnored private var waitingForPermission = false
    @ObservationIgnored private var best: (latitude: Double, longitude: Double, accuracy: Double)?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// Meters; a fix this good ends the reading early.
    private static let goodAccuracy: Double = 50
    private static let readingTimeout: Duration = .seconds(15)
    private static let deniedMessage = "لا يصل زمام إلى موقعك. اسمح له بالموقع من إعدادات النظام، أو ابحث عن المكان."
    private static let failedMessage = "تعذّر تحديد موقعك. ابحث عن المكان بدلاً منه."

    init() {
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.delegate = delegate
        delegate.onLocation = { [weak self] latitude, longitude, accuracy in
            self?.received(latitude: latitude, longitude: longitude, accuracy: accuracy)
        }
        delegate.onFailure = { [weak self] code in
            self?.failed(code)
        }
        delegate.onAuthorizationChange = { [weak self] status in
            self?.authorizationChanged(status)
        }
    }

    func read() {
        guard !isReading else { return }
        errorMessage = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            waitingForPermission = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            isDenied = true
            errorMessage = Self.deniedMessage
        default:
            start()
        }
    }

    private func start() {
        isReading = true
        best = nil
        manager.startUpdatingLocation()
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.readingTimeout)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        isReading = false
        if let best {
            coordinate = (best.latitude, best.longitude)
            onPlace?(best.latitude, best.longitude)
        } else {
            errorMessage = Self.failedMessage
        }
    }

    private func received(latitude: Double, longitude: Double, accuracy: Double) {
        guard isReading else { return }
        if best == nil || accuracy < (best?.accuracy ?? .infinity) {
            best = (latitude, longitude, accuracy)
        }
        if accuracy <= Self.goodAccuracy { finish() }
    }

    private func failed(_ code: CLError.Code?) {
        guard isReading else { return }
        switch code {
        case .some(.locationUnknown):
            return
        case .some(.denied):
            best = nil
            isDenied = true
            finish()
            errorMessage = Self.deniedMessage
        default:
            finish()
        }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            return
        case .denied, .restricted:
            isDenied = true
            if waitingForPermission {
                waitingForPermission = false
                errorMessage = Self.deniedMessage
            }
        default:
            isDenied = false
            if waitingForPermission {
                waitingForPermission = false
                start()
            }
        }
    }
}

/// CoreLocation's delegate for `CurrentPlaceReader`; its callbacks hop to the main actor.
private final class PlaceReaderDelegate: NSObject, CLLocationManagerDelegate {
    var onLocation: (@MainActor (Double, Double, Double) -> Void)?
    var onFailure: (@MainActor (CLError.Code?) -> Void)?
    var onAuthorizationChange: (@MainActor (CLAuthorizationStatus) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // A negative accuracy marks an invalid reading.
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let accuracy = location.horizontalAccuracy
        let handler = onLocation
        Task { @MainActor in handler?(latitude, longitude, accuracy) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let handler = onFailure
        Task { @MainActor in handler?(code) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let handler = onAuthorizationChange
        Task { @MainActor in handler?(status) }
    }
}
