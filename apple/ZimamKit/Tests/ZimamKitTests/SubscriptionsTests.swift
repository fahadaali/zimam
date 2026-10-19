import Foundation
import Testing
@testable import ZimamKit

struct SubscriptionsTests {
    @Test func decodesProPlanInTheServerShape() throws {
        // As in api/test/subscriptions.test.ts.
        let json = #"{"plan":"pro","expiresAt":1792000000000,"productId":"app.zimam.ios.pro.yearly","source":"apple","environment":"sandbox","enforced":false}"#
        let plan = try JSONDecoder().decode(SubscriptionPlan.self, from: Data(json.utf8))
        #expect(plan.isPro)
        #expect(plan.productId == ZimamPro.yearly)
        #expect(plan.source == .apple)
        #expect(plan.environment == "sandbox")
        #expect(!plan.enforced)
        #expect(plan.expiresDate == Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func decodesFreeAndOverridePlans() throws {
        let free = try JSONDecoder().decode(SubscriptionPlan.self, from: Data(
            #"{"plan":"free","expiresAt":null,"productId":null,"source":null,"environment":null,"enforced":true}"#.utf8))
        #expect(free == SubscriptionPlan(plan: .free, enforced: true))
        #expect(free.expiresDate == nil)

        let owner = try JSONDecoder().decode(SubscriptionPlan.self, from: Data(#"{"plan":"pro","source":"override","enforced":true}"#.utf8))
        #expect(owner.isPro)
        #expect(owner.source == .override)

        // Unknown values do not fail the screen.
        let odd = try JSONDecoder().decode(SubscriptionPlan.self, from: Data(#"{"plan":"team","source":"stripe"}"#.utf8))
        #expect(odd.plan == .free)
        #expect(odd.source == nil)
        #expect(!odd.enforced)
    }

    @Test func proRequiredErrors() {
        let error = APIError(status: 403, code: "pro_required", message: "This feature needs Zimam Pro")
        #expect(APIError.requiresPro(error))
        #expect(!APIError.requiresPro(APIError(status: 403, code: "forbidden", message: "")))
        #expect(!APIError.requiresPro(URLError(.notConnectedToInternet)))
        #expect(AssistantProblem(error) == .proRequired)
        #expect(AssistantProblem.proRequired.message().contains("زمام الاحترافية"))
        #expect(ImportText.message(for: error).contains("زمام الاحترافية"))
    }

    @Test func productsAndTexts() {
        #expect(ZimamPro.productIds == ["app.zimam.ios.pro.yearly", "app.zimam.ios.pro.monthly"])
        #expect(ZimamPro.periodName(productId: ZimamPro.monthly) == "شهرياً")
        #expect(ZimamPro.periodName(productId: ZimamPro.yearly) == "سنوياً")
        #expect(ZimamPro.periodName(productId: "other") == nil)
        #expect(SubscriptionText.message(for: APIError(status: 403, code: "account_mismatch", message: "")).contains("حساب آخر"))
        #expect(SubscriptionText.message(for: URLError(.notConnectedToInternet)).contains("الاتصال"))
        // No emoji and no middle dot next to numbers anywhere in what the paywall shows.
        let texts = ZimamPro.features.flatMap { [$0.title, $0.detail] } + [ZimamPro.freeSummary, ZimamPro.renewalTerms]
        for text in texts {
            #expect(!text.contains("·"), Comment(rawValue: text))
            #expect(!(text.unicodeScalars.contains { $0.properties.isEmojiPresentation }), Comment(rawValue: text))
        }
    }
}
