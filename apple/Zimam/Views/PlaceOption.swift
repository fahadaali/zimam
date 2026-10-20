import CoreLocation
import MapKit
import SwiftUI
import ZimamKit

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
