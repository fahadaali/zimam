import SwiftUI

/// Form rows that set the place for prayer times: «استعمال موقعي الحالي» (which asks for
/// permission the first time), progress while reading, the error, and a way to System Settings
/// when location is off for Zimam. Used in settings and wherever a prayer time needs a place.
struct LocationRequestRows: View {
    @Environment(LocationProvider.self) private var location
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(location.coordinate == nil ? "استعمال موقعي الحالي" : "تحديث موقعي", systemImage: "location") {
            location.requestLocation()
        }
        .disabled(location.isLocating)
        .frame(minHeight: ZimamSpacing.space11)
        if location.isLocating {
            ProgressView("جارٍ تحديد موقعك…")
                .font(ZimamType.callout)
                .frame(minHeight: ZimamSpacing.space11)
        }
        if let message = location.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.priorityHigh)
        }
        if location.isDenied, let url = LocationProvider.systemSettingsURL {
            Button("فتح إعدادات الموقع", systemImage: "gear") { openURL(url) }
                .frame(minHeight: ZimamSpacing.space11)
        }
    }
}
