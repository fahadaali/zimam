import Foundation

/// The Zimam website: its public pages, opened from the app, and the origin of invite links.
/// The site moves to https://zimam.app once the domain is attached; then `origin`, the
/// Associated Domains entitlement in apple/project.yml, `INVITE_URL` in
/// api/src/routes/members.ts and web/public/.well-known/apple-app-site-association change
/// together (docs/setup.md, «الروابط العامة»).
public enum ZimamWeb {
    public static let origin = URL(string: "https://zimam-web.fahad2ao.workers.dev")!

    /// سياسة الخصوصية (web/public/privacy/).
    public static let privacyPolicy = URL(string: "https://zimam-web.fahad2ao.workers.dev/privacy/")!
    /// شروط الاستخدام (web/public/terms/).
    public static let terms = URL(string: "https://zimam-web.fahad2ao.workers.dev/terms/")!

    /// Hosts whose `/join` links are invites: the current site, and zimam.app later.
    public static let inviteHosts: Set<String> = ["zimam-web.fahad2ao.workers.dev", "zimam.app", "www.zimam.app"]

    /// The app's own URL scheme, used by «فتح في التطبيق» on the web join page
    /// (`zimam://join/<code>`): Safari keeps a tap on a universal link to the page's own
    /// domain in the browser, so that button cannot use the https link.
    public static let appScheme = "zimam"
}
