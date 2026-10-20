import CoreLocation
import MapKit
import SwiftUI
import ZimamKit

/// «اختيار من الخريطة»: the place prayer times are computed for, picked by moving the map under a
/// pin or by searching for a city. It replaces the device's location until the user asks for
/// their location again (`LocationProvider.choose`). Kept apart from location reminders' places:
/// a reminder's place never moves the prayer times.
struct PrayerPlacePicker: View {
    @Environment(LocationProvider.self) private var location
    @Environment(\.dismiss) private var dismiss

    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    /// The name of the search result the map moved to, until the map is moved by hand.
    @State private var chosenName: String?
    @State private var query = ""
    @State private var results: [PlaceOption] = []
    @State private var isSaving = false

    /// Wide enough to see the city, close enough to place the pin in it.
    private static let span: CLLocationDistance = 20_000
    /// Mecca, before the first location.
    private static let fallback = CLLocationCoordinate2D(latitude: 21.4225, longitude: 39.8262)

    init(start: CLLocationCoordinate2D? = nil) {
        let center = start ?? Self.fallback
        _center = State(initialValue: center)
        _position = State(initialValue: .region(MKCoordinateRegion(center: center, latitudinalMeters: Self.span,
                                                                   longitudinalMeters: Self.span)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PrayerPlaceSearchField(query: $query)
                if !results.isEmpty {
                    PrayerPlaceResultsList(results: results, onPick: { pick($0) })
                } else {
                    PrayerPlaceMap(position: $position, onMove: { cameraMoved(to: $0) })
                }
                PrayerPlaceChooseBar(chosenName: chosenName, isSaving: isSaving, onChoose: { confirm() })
            }
            .background(ZimamColor.surface)
            .navigationTitle("اختيار المكان")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
            }
            .task(id: query) { await search(query) }
            .onAppear(perform: startAtLocation)
        }
        #if os(macOS)
        .frame(minWidth: ZimamLayout.settingsWidth, minHeight: ZimamLayout.windowMinHeight)
        #endif
    }

    // MARK: Actions

    private func startAtLocation() {
        if let coordinate = location.coordinate {
            move(to: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude), name: nil)
        }
    }

    private func pick(_ option: PlaceOption) {
        query = ""
        results = []
        move(to: CLLocationCoordinate2D(latitude: option.latitude, longitude: option.longitude), name: option.name)
    }

    /// The map was moved by hand: a search result's name no longer applies.
    private func cameraMoved(to moved: CLLocationCoordinate2D) {
        if abs(moved.latitude - center.latitude) > 0.0001 || abs(moved.longitude - center.longitude) > 0.0001 {
            chosenName = nil
        }
        center = moved
    }

    private func confirm() {
        Task { await choose() }
    }

    private func move(to coordinate: CLLocationCoordinate2D, name: String?) {
        center = coordinate
        chosenName = name
        position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: Self.span,
                                              longitudinalMeters: Self.span))
    }

    /// Saves the place under the pin with its city's name (or the search result's), then closes.
    private func choose() async {
        isSaving = true
        var name = chosenName
        if name == nil {
            let reading = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let placemark = try? await CLGeocoder()
                .reverseGeocodeLocation(reading, preferredLocale: Locale(identifier: "ar")).first
            name = placemark?.locality ?? placemark?.administrativeArea
        }
        location.choose(latitude: center.latitude, longitude: center.longitude, name: name)
        isSaving = false
        dismiss()
    }

    /// Cities and districts from Apple Maps, a moment after the user stops typing.
    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address]
        let response = try? await MKLocalSearch(request: request).start()
        guard !Task.isCancelled else { return }
        results = response?.mapItems.prefix(8).map(PlaceOption.init(item:)) ?? []
    }
}

/// The search field above the map.
private struct PrayerPlaceSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ZimamColor.inkMuted)
            TextField("ابحث عن مدينة أو حي", text: $query)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, ZimamSpacing.space3)
        .frame(minHeight: ZimamSpacing.space11)
        .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd).stroke(ZimamColor.lineStrong))
        .padding(ZimamSpacing.space4)
    }
}

/// The search's results, in place of the map while there are any.
private struct PrayerPlaceResultsList: View {
    let results: [PlaceOption]
    let onPick: (PlaceOption) -> Void

    var body: some View {
        List(results) { option in
            Button {
                onPick(option)
            } label: {
                PlaceOptionRow(option: option, isSelected: false)
            }
            .buttonStyle(.plain)
        }
        .scrollContentBackground(.hidden)
    }
}

/// The map moves under a fixed pin; where the pin points is the place.
private struct PrayerPlaceMap: View {
    @Binding var position: MapCameraPosition
    let onMove: (CLLocationCoordinate2D) -> Void

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
        }
            .onMapCameraChange(frequency: .onEnd) { context in
                onMove(context.region.center)
            }
            .overlay {
                Image(systemName: "mappin")
                    .font(ZimamType.display)
                    .foregroundStyle(ZimamColor.brand)
                    // The pin's tip, not its middle, marks the place.
                    .offset(y: -ZimamSpacing.space4)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("حرّك الخريطة ليكون الدبوس على مكانك")
    }
}

/// The chosen place's name, and «اعتماد هذا المكان».
private struct PrayerPlaceChooseBar: View {
    let chosenName: String?
    let isSaving: Bool
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            if let chosenName {
                Text(chosenName)
                    .font(ZimamType.headline)
                    .foregroundStyle(ZimamColor.ink)
            }
            Button(action: onChoose) {
                if isSaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("اعتماد هذا المكان")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.zimamPrimary)
            .disabled(isSaving)
        }
        .padding(ZimamSpacing.space4)
        .background(ZimamColor.surface)
    }
}
