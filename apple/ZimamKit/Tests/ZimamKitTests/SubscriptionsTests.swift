import XCTest
@testable import ZimamKit

final class SubscriptionsTests: XCTestCase {
    func testDecodesProPlanInTheServerShape() throws {
        // As in api/test/subscriptions.test.ts.
        let json = #"{"plan":"pro","expiresAt":1792000000000,"productId":"app.zimam.ios.pro.yearly","source":"apple","environment":"sandbox","enforced":false}"#
        let plan = try JSONDecoder().decode(SubscriptionPlan.self, from: Data(json.utf8))
        XCTAssertTrue(plan.isPro)
        XCTAssertEqual(plan.productId, ZimamPro.yearly)
        XCTAssertEqual(plan.source, .apple)
        XCTAssertEqual(plan.environment, "sandbox")
        XCTAssertFalse(plan.enforced)
        XCTAssertEqual(plan.expiresDate, Date(timeIntervalSince1970: 1_792_000_000))
    }

    func testDecodesFreeAndOverridePlans() throws {
        let free = try JSONDecoder().decode(SubscriptionPlan.self, from: Data(
            #"{"plan":"free","expiresAt":null,"productId":null,"source":null,"environment":null,"enforced":true}"#.utf8))
        XCTAssertEqual(free, SubscriptionPlan(plan: .free, enforced: true))
        XCTAssertNil(free.expiresDate)

        let owner = try JSONDecoder().decode(SubscriptionPlan.self, from: Data(#"{"plan":"pro","source":"override","enforced":true}"#.utf8))
        XCTAssertTrue(owner.isPro)
        XCTAssertEqual(owner.source, .override)

        // Unknown values do not fail the screen.
        let odd = try JSONDecoder().decode(SubscriptionPlan.self, from: Data(#"{"plan":"team","source":"stripe"}"#.utf8))
        XCTAssertEqual(odd.plan, .free)
        XCTAssertNil(odd.source)
        XCTAssertFalse(odd.enforced)
    }

    func testProRequiredErrors() {
        let error = APIError(status: 403, code: "pro_required", message: "This feature needs Zimam Pro")
        XCTAssertTrue(APIError.requiresPro(error))
        XCTAssertFalse(APIError.requiresPro(APIError(status: 403, code: "forbidden", message: "")))
        XCTAssertFalse(APIError.requiresPro(URLError(.notConnectedToInternet)))
        XCTAssertEqual(AssistantProblem(error), .proRequired)
        XCTAssertTrue(AssistantProblem.proRequired.message().contains("زمام الاحترافية"))
        XCTAssertTrue(ImportText.message(for: error).contains("زمام الاحترافية"))
    }

    func testProductsAndTexts() {
        XCTAssertEqual(ZimamPro.productIds, ["app.zimam.ios.pro.yearly", "app.zimam.ios.pro.monthly"])
        XCTAssertEqual(ZimamPro.periodName(productId: ZimamPro.monthly), "شهرياً")
        XCTAssertEqual(ZimamPro.periodName(productId: ZimamPro.yearly), "سنوياً")
        XCTAssertNil(ZimamPro.periodName(productId: "other"))
        XCTAssertTrue(SubscriptionText.message(for: APIError(status: 403, code: "account_mismatch", message: "")).contains("حساب آخر"))
        XCTAssertTrue(SubscriptionText.message(for: URLError(.notConnectedToInternet)).contains("الاتصال"))
        // No emoji and no middle dot next to numbers anywhere in what the paywall shows.
        let texts = ZimamPro.features.flatMap { [$0.title, $0.detail] } + [ZimamPro.freeSummary, ZimamPro.renewalTerms]
        for text in texts {
            XCTAssertFalse(text.contains("·"), text)
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmojiPresentation }, text)
        }
    }
}
