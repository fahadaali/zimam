import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The account's photo in a circle (`AvatarStore`), or the name's first letter on the brand's
/// soft colour when there is none.
struct AvatarView: View {
    let name: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = Self.image(from: AvatarStore.shared.data) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initial)
                    .font(size >= ZimamSpacing.space11 * 1.5 ? ZimamType.title : ZimamType.callout)
                    .foregroundStyle(ZimamColor.brandInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ZimamColor.brandSoft)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ZimamColor.line))
    }

    private var initial: String {
        guard let first = name?.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "ز" }
        return String(first)
    }

    private static func image(from data: Data?) -> Image? {
        guard let data else { return nil }
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #else
        return NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }
}
