import SwiftUI
import ZimamKit

/// Project name, «٧ من ١٢», and a progress bar with no written percentage. See design/components/ProjectCard.
struct ProjectCard: View {
    let name: String
    let done: Int
    let total: Int
    var active = false

    /// The app's locale (`ZimamLocale`), not the device's: the digits match the rest of the screen.
    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            Text(name)
                .font(ZimamType.headline)
                .foregroundStyle(active ? ZimamColor.brandInk : ZimamColor.ink)
            Text("\(formatter.number(done)) من \(formatter.number(total))")
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(ZimamColor.brand)
                .accessibilityHidden(true)
        }
        .padding(ZimamSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? ZimamColor.brandSoft : ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusLg).stroke(ZimamColor.line))
    }
}
