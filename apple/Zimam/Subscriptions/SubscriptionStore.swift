import Foundation
import Observation
import StoreKit
import ZimamKit

/// «زمام الاحترافية» with StoreKit 2: the products, purchases (with `appAccountToken` set to
/// the Zimam user id, which the server checks), restores, and the plan.
///
/// The server decides what pro unlocks (api/DEVELOPMENT.md, «الاشتراكات»): every verified
/// transaction goes to `POST /v1/subscriptions/apple`, which fetches it from Apple itself.
/// The plan shown is the server's, or the device's own entitlement while the server has not
/// caught up (offline, or a renewal it has not heard of yet). While the server's `enforced` is
/// false (the personal trial) the app shows the plan and never blocks anything.
@MainActor
@Observable
final class SubscriptionStore {
    /// The two products, yearly first; empty until loaded (or when the App Store is unreachable).
    private(set) var products: [Product] = []
    /// The plan as the server last answered it.
    private(set) var plan: SubscriptionPlan?
    /// What this Apple account is entitled to on this device (StoreKit's verified current
    /// entitlements), with the Zimam account each was bought for (`appAccountToken`).
    private var localEntitlements: Set<LocalEntitlement> = []
    /// The signed-in Zimam account, whose purchases stand in for the server's plan.
    private var userId: UUID?
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    /// An Arabic sentence about the last purchase or restore, shown under the products.
    var message: String?

    private let api: APIClient
    @ObservationIgnored private var updates: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
    }

    private struct LocalEntitlement: Hashable {
        let productId: String
        let account: UUID?
    }

    /// Every product this Apple account has here, whoever bought it: sent to the server, which
    /// decides (a subscription of a deleted Zimam account moves to the new one).
    private var localProductIds: Set<String> { Set(localEntitlements.map(\.productId)) }

    /// The products bought for the signed-in account: only these stand in for the server's plan.
    /// Another Zimam account's subscription on the same Apple account does not make this one
    /// pro, as on the server («مرتبط بحساب آخر»). Signed out, every one counts.
    private var ownProductIds: Set<String> {
        Set(localEntitlements.filter { userId == nil || $0.account == userId }.map(\.productId))
    }

    /// Pro on the server, or on this device while the server catches up.
    var isPro: Bool { plan?.isPro == true || !ownProductIds.isEmpty }

    /// Whether the server blocks pro features for free users. False during the personal trial.
    var isEnforced: Bool { plan?.enforced ?? false }

    /// The product the user is subscribed to, if known.
    var currentProductId: String? { plan?.productId ?? ownProductIds.sorted().first }

    /// Listens for transactions made outside the paywall (renewals, Ask to Buy, offer codes,
    /// another device) for as long as the app runs. Call once at launch.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    /// Loads the products (once) and the plan, and sends this device's entitlements to the
    /// server when it does not know about them. Signed out, only the products load.
    func refresh(signedIn: Bool, userId: UUID?) async {
        self.userId = signedIn ? userId : nil
        await loadProducts()
        await loadLocalEntitlements()
        guard signedIn else {
            plan = nil
            return
        }
        do {
            plan = try await api.subscription()
        } catch {
            // Offline: keep the last plan, and the device's entitlement stands in.
            return
        }
        if plan?.isPro == false, !localProductIds.isEmpty {
            await sendCurrentEntitlements()
        }
    }

    func loadProducts() async {
        guard products.isEmpty, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        let loaded = (try? await Product.products(for: ZimamPro.productIds)) ?? []
        products = ZimamPro.productIds.compactMap { id in loaded.first { $0.id == id } }
    }

    /// Buys `product` for the signed-in user. The server ties the subscription to `userId`
    /// through `appAccountToken`, so it cannot be claimed by another Zimam account.
    func purchase(_ product: Product, userId: UUID) async {
        guard !isPurchasing else { return }
        self.userId = userId
        message = nil
        isPurchasing = true
        defer { isPurchasing = false }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: [.appAccountToken(userId)])
        } catch {
            message = "تعذّر إتمام الشراء. حاول مرة أخرى."
            return
        }
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                message = "تعذّر التحقق من الشراء. حاول مرة أخرى أو اضغط «استعادة المشتريات»."
                return
            }
            await deliver(transaction, reportErrors: true)
            if isPro, message == nil { message = "اشتركت في «زمام الاحترافية». شكراً لك." }
        case .pending:
            message = "الشراء ينتظر الموافقة. يُفعَّل الاشتراك حين يكتمل."
        case .userCancelled:
            break
        @unknown default:
            break
        }
    }

    /// «استعادة المشتريات»: asks the App Store for this Apple account's purchases (it may ask
    /// to sign in), then sends every current subscription to the server.
    func restore() async {
        guard !isRestoring else { return }
        message = nil
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
        } catch {
            if let storeError = error as? StoreKitError, case .userCancelled = storeError { return }
            message = "تعذّر الوصول إلى App Store. حاول مرة أخرى."
            return
        }
        await loadLocalEntitlements()
        if localProductIds.isEmpty {
            message = "لا اشتراك في «زمام الاحترافية» لحساب Apple هذا."
            return
        }
        await sendCurrentEntitlements(reportErrors: true)
        if message == nil { message = isPro ? "استُعيد اشتراكك في «زمام الاحترافية»." : nil }
    }

    /// Forgets the server's plan on sign-out; the device's entitlements stay with the Apple account.
    func signedOut() {
        plan = nil
        message = nil
        userId = nil
    }

    // MARK: Transactions

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        // Unverified transactions are ignored: StoreKit could not prove they came from the App Store.
        guard case .verified(let transaction) = result else { return }
        await deliver(transaction, reportErrors: false)
        await loadLocalEntitlements()
    }

    /// Sends a verified transaction to the server, then finishes it. Finishing does not lose
    /// anything: a subscription stays in `currentEntitlements`, which `refresh` sends again
    /// whenever the server's plan disagrees with the device.
    private func deliver(_ transaction: StoreKit.Transaction, reportErrors: Bool) async {
        if ZimamPro.productIds.contains(transaction.productID) {
            await send(transaction, reportErrors: reportErrors)
            if transaction.revocationDate == nil {
                localEntitlements.insert(LocalEntitlement(productId: transaction.productID, account: transaction.appAccountToken))
            }
        }
        await transaction.finish()
    }

    private func send(_ transaction: StoreKit.Transaction, reportErrors: Bool) async {
        do {
            plan = try await api.verifyAppleTransaction(id: transaction.id, environment: Self.environment(of: transaction))
        } catch {
            if reportErrors { message = SubscriptionText.message(for: error) }
        }
    }

    private func sendCurrentEntitlements(reportErrors: Bool = false) async {
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, ZimamPro.productIds.contains(transaction.productID) else { continue }
            await send(transaction, reportErrors: reportErrors)
        }
    }

    private func loadLocalEntitlements() async {
        var found: Set<LocalEntitlement> = []
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil,
               ZimamPro.productIds.contains(transaction.productID) {
                found.insert(LocalEntitlement(productId: transaction.productID, account: transaction.appAccountToken))
            }
        }
        localEntitlements = found
    }

    /// Where the server should look first. Xcode's local StoreKit testing has no server
    /// counterpart: those transactions are not known to Apple, and the server answers 404.
    private static func environment(of transaction: StoreKit.Transaction) -> String? {
        switch transaction.environment {
        case .production: "production"
        case .sandbox: "sandbox"
        default: nil
        }
    }
}
