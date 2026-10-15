import StoreKit
import SwiftUI
import ZimamKit

/// «زمام الاحترافية» as a sheet: from a feature the server refused with `pro_required`
/// (the assistant, an import). Settings pushes `PaywallContent` itself.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PaywallContent()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("إغلاق") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: ZimamSpacing.space8 * 14, minHeight: ZimamSpacing.space8 * 18)
        #endif
    }
}

/// What the subscription adds, the two products with the App Store's own localized prices
/// («١٩٫٩٩ ر.س» for a Saudi account, formatted by StoreKit, never typed here), restore,
/// managing the subscription, and the terms and privacy links App Review asks for.
/// While the server does not enforce plans (the personal trial), it says nothing is locked.
struct PaywallContent: View {
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(SessionStore.self) private var session
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.openURL) private var openURL

    @State private var managing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZimamSpacing.space6) {
                header
                if subscriptions.isPro { statusCard }
                featureList
                productList
                actions
                legal
            }
            .padding(ZimamSpacing.space4)
            .frame(maxWidth: ZimamSpacing.space8 * 18, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ZimamColor.surface)
        .navigationTitle(ZimamPro.groupName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $managing)
        #endif
        .task { await subscriptions.refresh(signedIn: session.isSignedIn) }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            Text(ZimamPro.groupName)
                .font(ZimamType.title)
                .lineSpacing(ZimamType.titleLineSpacing)
                .foregroundStyle(ZimamColor.ink)
                .accessibilityAddTraits(.isHeader)
            Text(ZimamPro.freeSummary)
                .font(ZimamType.callout)
                .lineSpacing(ZimamType.calloutLineSpacing)
                .foregroundStyle(ZimamColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if !subscriptions.isEnforced {
                Text("في فترة التجربة كل المزايا متاحة لك دون اشتراك.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.brandInk)
                    .padding(ZimamSpacing.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ZimamColor.brandSoft, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Label("أنت مشترك في «زمام الاحترافية»", systemImage: "checkmark.seal")
                .font(ZimamType.headline)
                .foregroundStyle(ZimamColor.success)
            if let period = subscriptions.currentProductId.flatMap(ZimamPro.periodName(productId:)) {
                Text("الاشتراك \(period)")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.ink)
            }
            if let end = subscriptions.plan?.expiresDate {
                Text("الفترة الحالية حتى \(formatter.dual(end, withYear: true))")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            } else if subscriptions.plan?.source == .override {
                Text("مفعّل لحسابك دون اشتراك.")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
        .padding(ZimamSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusLg).stroke(ZimamColor.line))
        .accessibilityElement(children: .combine)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space4) {
            Text("ما تضيفه الاحترافية")
                .font(ZimamType.headline)
                .foregroundStyle(ZimamColor.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(ZimamPro.features) { feature in
                HStack(alignment: .top, spacing: ZimamSpacing.space3) {
                    Image(systemName: feature.systemImage)
                        .foregroundStyle(ZimamColor.brand)
                        .frame(width: ZimamSpacing.space6)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                        Text(feature.title)
                            .font(ZimamType.body.weight(.semibold))
                            .foregroundStyle(ZimamColor.ink)
                        Text(feature.detail)
                            .font(ZimamType.callout)
                            .lineSpacing(ZimamType.calloutLineSpacing)
                            .foregroundStyle(ZimamColor.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var productList: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space3) {
            if subscriptions.products.isEmpty {
                if subscriptions.isLoadingProducts {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
                } else {
                    Text("تعذّر تحميل الأسعار من App Store. تحقّق من الاتصال ثم أعد فتح الصفحة.")
                        .font(ZimamType.callout)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
            }
            ForEach(subscriptions.products, id: \.id) { product in
                ProductRow(product: product,
                           isCurrent: subscriptions.isPro && subscriptions.currentProductId == product.id,
                           isEnabled: canPurchase) {
                    guard let userId = session.user?.id else { return }
                    Task { await subscriptions.purchase(product, userId: userId) }
                }
            }
            if session.user == nil {
                Text("سجّل الدخول لتشترك، فيرتبط الاشتراك بحسابك في زمام.")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            if subscriptions.isPurchasing {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
            }
            if let message = subscriptions.message {
                Text(message)
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canPurchase: Bool {
        session.user != nil && !subscriptions.isPurchasing && !subscriptions.isRestoring
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Button {
                Task { await subscriptions.restore() }
            } label: {
                HStack(spacing: ZimamSpacing.space2) {
                    if subscriptions.isRestoring { ProgressView() }
                    Text("استعادة المشتريات")
                }
            }
            .buttonStyle(.zimamQuiet)
            .disabled(subscriptions.isRestoring || subscriptions.isPurchasing)
            if subscriptions.isPro && subscriptions.plan?.source != .override {
                Button("إدارة الاشتراك", action: manage)
                    .buttonStyle(.zimamQuiet)
            }
        }
    }

    private var legal: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            Text(ZimamPro.renewalTerms)
                .font(ZimamType.caption)
                .lineSpacing(ZimamType.captionLineSpacing)
                .foregroundStyle(ZimamColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ZimamSpacing.space4) {
                Link("شروط الاستخدام", destination: ZimamPro.termsURL)
                    .frame(minHeight: ZimamSpacing.space11)
                Link("سياسة الخصوصية", destination: ZimamPro.privacyURL)
                    .frame(minHeight: ZimamSpacing.space11)
            }
            .font(ZimamType.caption.weight(.semibold))
            .foregroundStyle(ZimamColor.brand)
        }
    }

    private func manage() {
        #if os(iOS)
        managing = true
        #else
        openURL(ZimamPro.manageURL)
        #endif
    }
}

/// One product: its App Store name, the period, and the localized price. A bordered row
/// (`line-strong`, as interactive elements are), at least 44pt tall.
private struct ProductRow: View {
    let product: Product
    let isCurrent: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZimamSpacing.space3) {
                VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                    Text(product.displayName)
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.ink)
                    if isCurrent {
                        Text("اشتراكك الحالي")
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.success)
                    } else if let period = ZimamPro.periodName(productId: product.id) {
                        Text(period)
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                }
                Spacer(minLength: ZimamSpacing.space2)
                // StoreKit formats the price for the account's storefront: «١٩٫٩٩ ر.س».
                Text(product.displayPrice)
                    .font(ZimamType.headline)
                    .foregroundStyle(isCurrent ? ZimamColor.inkMuted : ZimamColor.brand)
            }
            .padding(.horizontal, ZimamSpacing.space4)
            .padding(.vertical, ZimamSpacing.space3)
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            .background(ZimamColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd).stroke(isCurrent ? ZimamColor.line : ZimamColor.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isCurrent)
        .accessibilityLabel("\(product.displayName)، \(product.displayPrice)")
        .accessibilityHint(isCurrent ? "اشتراكك الحالي" : "اشتراك")
    }
}
