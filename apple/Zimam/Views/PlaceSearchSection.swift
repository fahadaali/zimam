import CoreLocation
import MapKit
import SwiftUI
import ZimamKit

// MARK: Finding a place

/// Apple Maps search near the user's area, and «استعمال موقعي الحالي». Shared by the reminder
/// sheet and «أماكني».
struct PlaceSearchSection: View {
    enum SearchPhase: Equatable { case idle, searching, empty, failed }

    /// How far around the user's area the search looks first.
    private static let searchSpanMeters: CLLocationDistance = 50_000
    private static let maxResults = 8

    @Environment(LocationProvider.self) private var location

    let title: String
    let selection: PlaceOption?
    let onChoose: (PlaceOption) -> Void

    @State private var reader = CurrentPlaceReader()
    @State private var query = ""
    @State private var results: [PlaceOption] = []
    @State private var phase: SearchPhase = .idle

    init(title: String, selection: PlaceOption?, onChoose: @escaping (PlaceOption) -> Void) {
        self.title = title
        self.selection = selection
        self.onChoose = onChoose
    }

    var body: some View {
        Section {
            TextField(hint: "ابحث عن مكان أو عنوان", text: $query)
                .labelsHidden()
                .autocorrectionDisabled()
            CurrentPlaceRows(reader: reader)
            PlaceSearchPhaseRow(phase: phase)
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
        .onAppear(perform: startListening)
        // The closure holds this view, whose state holds the reader: let go on close.
        .onDisappear { reader.onPlace = nil }
    }

    private func startListening() {
        reader.onPlace = { latitude, longitude in
            onChoose(PlaceOption(name: "موقعي الحالي", detail: nil, latitude: latitude, longitude: longitude,
                                 isCurrentLocation: true))
        }
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

/// «استعمال موقعي الحالي», and the reading's progress, its error, and the way to the settings.
private struct CurrentPlaceRows: View {
    let reader: CurrentPlaceReader

    var body: some View {
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
    }
}

/// The search's progress, or why it found nothing.
private struct PlaceSearchPhaseRow: View {
    let phase: PlaceSearchSection.SearchPhase

    var body: some View {
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
    }
}

/// How far around a place counts as being there, ١٠٠ م to ١ كم. The circle on the map above it
/// follows the slider as it moves.
struct RadiusSlider: View {
    @Environment(\.dateFormatterZimam) private var formatter

    @Binding var radius: Double

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
