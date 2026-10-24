import Foundation
import Testing
@testable import ZimamKit

struct AppLinkTests {
    @Test func linksRoundTrip() {
        let id = UUID()
        let links: [AppLink] = [.today, .calendar, .day("2026-10-15"), .task(id), .prayer, .matrix]
        for link in links {
            #expect(AppLink(url: link.url) == link)
        }
        #expect(AppLink.day("2026-10-15").url.absoluteString == "zimam://day/2026-10-15")
        #expect(AppLink.task(id).url.absoluteString == "zimam://task/\(id.uuidString)")
        #expect(AppLink.today.url.absoluteString == "zimam://today")
        #expect(AppLink.matrix.url.absoluteString == "zimam://matrix")
    }

    @Test func readsLowercaseIds() {
        let id = UUID()
        #expect(AppLink(url: URL(string: "zimam://task/\(id.uuidString.lowercased())")!) == .task(id))
    }

    @Test func rejectsOtherLinks() {
        // Invites belong to InviteCode.
        #expect(AppLink(url: URL(string: "zimam://join/abc123")!) == nil)
        #expect(AppLink(url: URL(string: "https://zimam.work/today")!) == nil)
        #expect(AppLink(url: URL(string: "zimam://task/not-a-uuid")!) == nil)
        #expect(AppLink(url: URL(string: "zimam://day/15-10-2026")!) == nil)
        #expect(AppLink(url: URL(string: "zimam://day/2026-1-5")!) == nil)
        #expect(AppLink(url: URL(string: "zimam://day")!) == nil)
        #expect(AppLink(url: URL(string: "zimam://today/extra")!) == nil)
        #expect(AppLink(url: URL(string: "zimam://matrix/extra")!) == nil)
    }
}
