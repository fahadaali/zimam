import Foundation

/// The Zimam website: its public pages, opened from the app, and the origin of invite links.
/// `origin`, the Associated Domains entitlement in apple/project.yml, `INVITE_URL` in
/// api/src/routes/members.ts and web/public/.well-known/apple-app-site-association change
/// together (docs/setup.md, «الروابط العامة»).
public enum ZimamWeb {
    public static let origin = URL(string: "https://zimam.work")!

    /// سياسة الخصوصية (web/public/privacy/).
    public static let privacyPolicy = URL(string: "https://zimam.work/privacy/")!
    /// شروط الاستخدام (web/public/terms/).
    public static let terms = URL(string: "https://zimam.work/terms/")!

    /// Hosts whose `/join` links are invites: the site, with or without www.
    public static let inviteHosts: Set<String> = ["zimam.work", "www.zimam.work"]

    /// The app's own URL scheme, used by «فتح في التطبيق» on the web join page
    /// (`zimam://join/<code>`): Safari keeps a tap on a universal link to the page's own
    /// domain in the browser, so that button cannot use the https link.
    public static let appScheme = "zimam"
}
