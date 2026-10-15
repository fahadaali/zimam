import XCTest
@testable import ZimamKit

final class AppLinkTests: XCTestCase {
    func testLinksRoundTrip() {
        let id = UUID()
        let links: [AppLink] = [.today, .calendar, .day("2026-10-15"), .task(id)]
        for link in links {
            XCTAssertEqual(AppLink(url: link.url), link)
        }
        XCTAssertEqual(AppLink.day("2026-10-15").url.absoluteString, "zimam://day/2026-10-15")
        XCTAssertEqual(AppLink.task(id).url.absoluteString, "zimam://task/\(id.uuidString)")
        XCTAssertEqual(AppLink.today.url.absoluteString, "zimam://today")
    }

    func testReadsLowercaseIds() {
        let id = UUID()
        XCTAssertEqual(AppLink(url: URL(string: "zimam://task/\(id.uuidString.lowercased())")!), .task(id))
    }

    func testRejectsOtherLinks() {
        // Invites belong to InviteCode.
        XCTAssertNil(AppLink(url: URL(string: "zimam://join/abc123")!))
        XCTAssertNil(AppLink(url: URL(string: "https://zimam.app/today")!))
        XCTAssertNil(AppLink(url: URL(string: "zimam://task/not-a-uuid")!))
        XCTAssertNil(AppLink(url: URL(string: "zimam://day/15-10-2026")!))
        XCTAssertNil(AppLink(url: URL(string: "zimam://day/2026-1-5")!))
        XCTAssertNil(AppLink(url: URL(string: "zimam://day")!))
        XCTAssertNil(AppLink(url: URL(string: "zimam://today/extra")!))
    }
}
