import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import ZimamKit

/// The account's photo («صورة العرض»): kept on the server (`PUT /v1/me/avatar`) so every device
/// shows it, and cached in the Caches folder with the version it was downloaded at
/// (`User.avatarVersion`), so it is fetched again only after it changes.
@MainActor
@Observable
final class AvatarStore {
    static let shared = AvatarStore()

    /// The photo's bytes, or nil (the name's first letter is shown).
    private(set) var data: Data?
    private(set) var isSaving = false

    @ObservationIgnored private var loadedVersion: Milliseconds?

    private static let versionKey = "avatar.version"
    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("zimam-avatar.jpg")
    }

    private init() {}

    /// Brings the photo in step with the account: from the cache when the version matches,
    /// otherwise from the server. Without a network the last one stays.
    func refresh(session: SessionStore) async {
        guard let version = session.user?.avatarVersion else {
            clear()
            return
        }
        if loadedVersion == version, data != nil { return }
        let cachedVersion = (UserDefaults.standard.object(forKey: Self.versionKey) as? NSNumber)?.int64Value
        if cachedVersion == version, let url = Self.fileURL, let cached = try? Data(contentsOf: url) {
            data = cached
            loadedVersion = version
            return
        }
        guard let downloaded = try? await session.api.avatar() else { return }
        keep(downloaded, version: version)
    }

    /// Crops the picked image to a square of `AvatarImage.side` and uploads it. False when the image
    /// could not be read or the server could not be reached.
    func upload(_ original: Data, session: SessionStore) async -> Bool {
        guard let jpeg = AvatarImage.squareJPEG(from: original) else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let user = try await session.api.uploadAvatar(jpeg: jpeg)
            session.setUser(user)
            keep(jpeg, version: user.avatarVersion)
            return true
        } catch {
            return false
        }
    }

    func remove(session: SessionStore) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            session.setUser(try await session.api.deleteAvatar())
            clear()
            return true
        } catch {
            return false
        }
    }

    /// Forgets the photo on this device: on sign-out, and when the account has none.
    func clear() {
        data = nil
        loadedVersion = nil
        UserDefaults.standard.removeObject(forKey: Self.versionKey)
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    private func keep(_ photo: Data, version: Milliseconds?) {
        data = photo
        loadedVersion = version
        if let url = Self.fileURL, (try? photo.write(to: url, options: .atomic)) != nil, let version {
            UserDefaults.standard.set(NSNumber(value: version), forKey: Self.versionKey)
        }
    }
}

/// Makes the uploaded photo: the middle square of the image, at most `side` pixels, as JPEG.
/// ImageIO, so the same code runs on iPhone, iPad and Mac, and applies the photo's orientation.
nonisolated enum AvatarImage {
    static let side = 512

    static func squareJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side * 2,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let edge = min(image.width, image.height)
        let crop = CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)
        guard let square = image.cropping(to: crop) else { return nil }
        let target = min(side, edge)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let jpeg = output as Data
        return jpeg.count <= APIClient.maxAvatarBytes ? jpeg : nil
    }
}
