import SwiftUI
import ZimamKit

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
                    Button("السماح بالموقع دائماً", systemImage: "location", action: requestAlways)
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

    private func requestAlways() {
        location.requestAlwaysAuthorization()
    }

    private var settingsLabel: String {
        if location.isDenied { return "السماح بالموقع من الإعدادات" }
        if !location.isPrecise { return "تفعيل «الموقع الدقيق» من الإعدادات" }
        return "اختيار «دائماً» من الإعدادات"
    }
}
