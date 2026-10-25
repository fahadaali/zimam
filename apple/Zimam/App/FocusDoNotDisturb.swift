#if os(iOS)
import SwiftUI
import UIKit

/// «عدم الإزعاج مع التركيز»: Apple lets no app turn a Focus mode on or off, so Zimam runs two
/// shortcuts the user makes once in Shortcuts, each with «تعيين التركيز»: «بدء تركيز زمام» when
/// «بدء التركيز» starts the Live Activity in a task's details, and «إنهاء تركيز زمام» when it
/// ends. Shortcuts opens for a moment and comes back through `zimam://focus`.
/// A shortcut opens only while the app is in front. A focus ended from the Live Activity, or by
/// completing its task elsewhere, runs the end shortcut when the app is next opened (`catchUp`).
/// Kept on this device: Do Not Disturb is set per device.
@MainActor
@Observable
final class FocusDoNotDisturb {
    static let shared = FocusDoNotDisturb()

    static let startShortcut = "بدء تركيز زمام"
    static let endShortcut = "إنهاء تركيز زمام"

    var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: Self.onKey) }
    }

    /// The start shortcut ran and the end one has not yet: only then is there something to turn off,
    /// so a focus started before turning this on, or from the user's own shortcut, is left alone.
    private var startedDoNotDisturb: Bool {
        didSet { UserDefaults.standard.set(startedDoNotDisturb, forKey: Self.startedKey) }
    }

    private static let onKey = "focus.doNotDisturb.on"
    private static let startedKey = "focus.doNotDisturb.started"
    private static let returnURL = URL(string: "zimam://focus")!

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.onKey)
        startedDoNotDisturb = UserDefaults.standard.bool(forKey: Self.startedKey)
    }

    /// After «بدء التركيز» started the Live Activity.
    func focusStarted() {
        guard isOn else { return }
        startedDoNotDisturb = true
        run(Self.startShortcut)
    }

    /// After a focus ended. Runs the end shortcut when no focus remains and the app is in front;
    /// otherwise `catchUp` runs it later.
    func focusEnded() {
        guard startedDoNotDisturb, !FocusActivity.isAnyRunning,
              UIApplication.shared.applicationState == .active else { return }
        startedDoNotDisturb = false
        run(Self.endShortcut)
    }

    /// When the app comes to the front: a focus that ended while it was away.
    func catchUp() {
        focusEnded()
    }

    /// Takes Shortcuts' return link, which only brings the app back.
    static func handleOpenURL(_ url: URL) -> Bool {
        url.scheme == returnURL.scheme && url.host() == returnURL.host()
    }

    /// The Shortcuts app, where the user makes the two shortcuts.
    static let shortcutsURL = URL(string: "shortcuts://")!

    private func run(_ name: String) {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            // A missing shortcut, or one stopped midway, also comes back.
            URLQueryItem(name: "x-success", value: Self.returnURL.absoluteString),
            URLQueryItem(name: "x-error", value: Self.returnURL.absoluteString),
            URLQueryItem(name: "x-cancel", value: Self.returnURL.absoluteString),
        ]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }
}
#endif
