import CoreLocation
import MapKit
import SwiftUI
import ZimamKit

/// «تذكير بالموقع»: the user finds a place with Apple Maps search (names come in Arabic, the
/// app's only localization) or takes the current location, names it, sets how far around it
/// counts (١٠٠ م to ١ كم) and whether to remind on arriving or on leaving. Nothing is saved
/// until «إضافة». The place syncs with the reminder; the device watches it (`NotificationScheduler`).
struct LocationReminderSheet: View {
    let onAdd: (ReminderRecord.Location) -> Void

    enum SearchPhase: Equatable { case idle, searching, empty, failed }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(LocationProvider.self) private var location

    @State private var reader = CurrentPlaceReader()
    @State private var query = ""
    @State private var results: [PlaceOption] = []
    @State private var phase: SearchPhase = .idle
    @State private var place: PlaceOption?
    @State private var name = ""
    @State private var radius = LocationReminderPlanner.defaultRadius
    @State private var trigger: ReminderRecord.Location.Trigger = .arrive

    /// How far around the user's area the search looks first.
    private static let searchSpanMeters: CLLocationDistance = 50_000
    private static let maxResults = 8

    init(onAdd: @escaping (ReminderRecord.Location) -> Void) {
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                if let place {
                    chosenSection(place)
                    triggerSection
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
                        .disabled(place == nil)
                }
            }
            .task(id: query) { await search(query) }
            .onAppear {
                reader.onPlace = { latitude, longitude in
                    choose(PlaceOption(name: "موقعي الحالي", detail: nil, latitude: latitude, longitude: longitude,
                                       isCurrentLocation: true))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 14, minHeight: ZimamSpacing.space8 * 18)
        #endif
    }

    // MARK: Finding the place

    private var searchSection: some View {
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
                Button { choose(option) } label: {
                    PlaceOptionRow(option: option, isSelected: option == place)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("المكان")
        }
    }

    // MARK: The chosen place

    private func chosenSection(_ place: PlaceOption) -> some View {
        Section {
            TextField("اسم المكان، مثل البيت أو المكتب", text: $name)
            PlacePreview(place: place, radius: radius)
        } header: {
            Text("المكان المختار")
        } footer: {
            Text("يظهر الاسم في التذكير: «\(LocationReminderPlanner.body(placeName: name, trigger: trigger, taskTitle: "المهمة"))».")
        }
    }

    private var triggerSection: some View {
        Section {
            Picker("التذكير", selection: $trigger) {
                Text(LocationReminderPlanner.triggerText(.arrive)).tag(ReminderRecord.Location.Trigger.arrive)
                Text(LocationReminderPlanner.triggerText(.leave)).tag(ReminderRecord.Location.Trigger.leave)
            }
            VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                HStack(spacing: ZimamSpacing.space2) {
                    Text("نطاق المكان")
                    Spacer(minLength: ZimamSpacing.space2)
                    Text(radiusText(radius))
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                Slider(value: $radius, in: LocationReminderPlanner.radiusRange, step: LocationReminderPlanner.radiusStep) {
                    Text("نطاق المكان")
                } minimumValueLabel: {
                    Text(radiusText(LocationReminderPlanner.radiusRange.lowerBound))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                } maximumValueLabel: {
                    Text(radiusText(LocationReminderPlanner.radiusRange.upperBound))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                .frame(minHeight: ZimamSpacing.space11)
                .accessibilityValue(radiusText(radius))
            }
            .padding(.vertical, ZimamSpacing.space1)
        } footer: {
            #if os(iOS)
            Text("يصلك التذكير كلما دخلت النطاق أو خرجت منه حتى تنجز المهمة. النطاق الأوسع أدق في الأماكن الكبيرة.")
            #else
            Text("تذكيرات الموقع تصل على الآيفون والآيباد، ولا تعمل على الماك.")
            #endif
        }
    }

    private func radiusText(_ meters: Double) -> String {
        LocationReminderPlanner.radiusText(meters, locale: formatter.locale)
    }

    // MARK: Actions

    private func choose(_ option: PlaceOption) {
        // Keeps a name the user typed; replaces the previous place's own name.
        let previousName = place.map { $0.isCurrentLocation ? "" : $0.name } ?? ""
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == previousName {
            name = option.isCurrentLocation ? "" : option.name
        }
        place = option
    }

    private func add() {
        guard let place else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = ReminderRecord.Location(
            latitude: place.latitude,
            longitude: place.longitude,
            radius: min(max(radius, LocationReminderPlanner.serverRadiusRange.lowerBound),
                        LocationReminderPlanner.serverRadiusRange.upperBound),
            name: trimmed.isEmpty ? nil : String(trimmed.prefix(200)),
            trigger: trigger
        )
        onAdd(saved)
        dismiss()
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

private struct PlaceOptionRow: View {
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
private struct PlacePreview: View {
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
