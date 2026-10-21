import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// «زمام الاحترافية» (api/src/routes/subscriptions.ts). The app buys with StoreKit 2 and sends
// each verified transaction id to the server, which fetches it from Apple and keeps the plan.

/// The subscription group and its products. Prices and their currency come from the App Store.
public enum ZimamPro {
    public static let groupName = "زمام الاحترافية"
    public static let monthly = "app.zimam.ios.pro.monthly"
    public static let yearly = "app.zimam.ios.pro.yearly"
    /// Yearly first, as the paywall lists them.
    public static let productIds = [yearly, monthly]

    public struct Feature: Identifiable, Equatable, Sendable {
        public let title: String
        public let detail: String
        public let systemImage: String
        public var id: String { title }
    }

    /// What the subscription adds, as docs/idea.md («نموذج الربح والاشتراكات») lists it, limited
    /// to what the server actually gates (api/DEVELOPMENT.md, «الاشتراكات»).
    public static let features: [Feature] = [
        Feature(title: "المساعد الذكي", detail: "اكتب المهمة بجملة، وقسّمها إلى خطوات، واقرأ ملخص يومك، بحصة شهرية.",
                systemImage: "text.bubble"),
        Feature(title: "زمام في كلود وChatGPT", detail: "اربط حسابك بخادم MCP لتسأل عن مهامك وتضيفها من المحادثة.",
                systemImage: "point.3.connected.trianglepath.dotted"),
        Feature(title: "الاستيراد من كل المصادر", detail: "انقل مهامك من Todoist وTickTick وGoogle Tasks وملفات CSV.",
                systemImage: "square.and.arrow.down"),
    ]

    /// What stays free, so the paywall says it plainly.
    public static let freeSummary = "المهام والمشاريع، والتقويمان الهجري والميلادي، وتذكيرات الصلاة، والويدجت، وسيري، والاستيراد من تذكيرات أبل تبقى مجانية."

    /// Shown under the products, as App Review expects for auto-renewing subscriptions.
    public static let renewalTerms = "يتجدد الاشتراك تلقائياً ويُخصم من حساب Apple ما لم تلغه قبل نهاية الفترة بأربع وعشرين ساعة على الأقل. تديره وتلغيه من إعدادات حسابك في App Store."

    public static let termsURL = URL(string: "https://zimam.work/terms")!
    public static let privacyURL = URL(string: "https://zimam.work/privacy")!
    /// Where subscriptions are managed when the system sheet is not available (the Mac).
    public static let manageURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    /// «شهرياً», «سنوياً» for the two products; nil for anything else.
    public static func periodName(productId: String) -> String? {
        switch productId {
        case monthly: "شهرياً"
        case yearly: "سنوياً"
        default: nil
        }
    }
}

/// `GET /v1/subscriptions`: the user's plan as the server sees it.
public struct SubscriptionPlan: Decodable, Equatable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case free, pro
    }

    public enum Source: String, Decodable, Sendable {
        /// An App Store subscription.
        case apple
        /// The server's PRO_USERS list (the owner).
        case override
    }

    public var plan: Kind
    /// When the paid period ends; nil for free and for the owner's override.
    public var expiresAt: Milliseconds?
    public var productId: String?
    public var source: Source?
    /// "sandbox" for TestFlight and sandbox accounts, "production" for the App Store.
    public var environment: String?
    /// False during the personal trial: the server blocks nothing, whatever the plan.
    public var enforced: Bool

    public var isPro: Bool { plan == .pro }

    public var expiresDate: Date? {
        expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    public init(plan: Kind, expiresAt: Milliseconds? = nil, productId: String? = nil, source: Source? = nil,
                environment: String? = nil, enforced: Bool = false) {
        self.plan = plan
        self.expiresAt = expiresAt
        self.productId = productId
        self.source = source
        self.environment = environment
        self.enforced = enforced
    }

    private enum CodingKeys: String, CodingKey {
        case plan, expiresAt, productId, source, environment, enforced
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = (try? c.decode(Kind.self, forKey: .plan)) ?? .free
        expiresAt = try c.decodeIfPresent(Milliseconds.self, forKey: .expiresAt)
        productId = try c.decodeIfPresent(String.self, forKey: .productId)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap(Source.init(rawValue:))
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        enforced = try c.decodeIfPresent(Bool.self, forKey: .enforced) ?? false
    }
}

public extension APIError {
    /// `403 pro_required`: the feature needs «زمام الاحترافية» (only when the server enforces plans).
    var isProRequired: Bool { code == "pro_required" }

    /// True for `403 pro_required` errors; false for anything else, including transport failures.
    static func requiresPro(_ error: Error) -> Bool {
        (error as? APIError)?.isProRequired ?? false
    }
}

public extension APIClient {
    /// `GET /v1/subscriptions`: the current plan.
    func subscription() async throws -> SubscriptionPlan {
        try await send("GET", "v1/subscriptions")
    }

    /// `POST /v1/subscriptions/apple`: a StoreKit transaction (after a purchase, a renewal or a
    /// restore) for the server to verify with Apple. Answers the plan. `environment` is
    /// "production" or "sandbox" and only decides where the server looks first.
    func verifyAppleTransaction(id: UInt64, environment: String?) async throws -> SubscriptionPlan {
        struct Body: Encodable {
            let transactionId: String
            let environment: String?
        }
        return try await send("POST", "v1/subscriptions/apple", body: Body(transactionId: String(id), environment: environment))
    }
}

/// Why verifying a purchase with the server failed, in Arabic.
public enum SubscriptionText {
    public static func message(for error: Error) -> String {
        guard let api = error as? APIError else {
            return NetworkFailure.isOffline(error)
                ? "تعذّر الاتصال بزمام. اشتراكك محفوظ عند Apple، وسيُفعَّل حين يعود الاتصال."
                : "تعذّر إتمام الاشتراك. حاول مرة أخرى."
        }
        switch api.code {
        case "account_mismatch", "already_linked":
            return "هذا الاشتراك مرتبط بحساب آخر في زمام. سجّل الدخول بذلك الحساب لتستعمله."
        case "transaction_not_found":
            return "لم يجد App Store هذا الشراء بعد. حاول بعد قليل أو اضغط «استعادة المشتريات»."
        case "wrong_bundle", "unknown_product":
            return "هذا الشراء ليس اشتراكاً في «زمام الاحترافية»."
        case "subscriptions_unavailable":
            return "تعذّر التحقق من الاشتراك الآن. اشتراكك محفوظ عند Apple، وسيُفعَّل بعد قليل."
        case "unauthorized":
            return "انتهت الجلسة. سجّل الدخول مرة أخرى."
        default:
            return "تعذّر إتمام الاشتراك. حاول مرة أخرى."
        }
    }
}
