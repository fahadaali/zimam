import SwiftUI
import ZimamKit

/// The assistant's suggestion card. See design/components/AISuggestion.
/// `brandSoft` background, the label in `brandInk`, the content as one or two sentences in
/// the past tense («قسّمت…»), then accept and dismiss. Nothing is applied before accepting.
/// No sparkles or gradients: the identity stays calm.
struct AssistantSuggestion<Content: View>: View {
    var label = "اقتراح المساعد"
    var acceptLabel = "اعتماد"
    var dismissLabel = "تجاهل"
    /// An optional third action between accept and dismiss, such as «تعديل».
    var secondaryLabel: String?
    var onAccept: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onDismiss: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            Text(label)
                .font(ZimamType.caption.weight(.semibold))
                .foregroundStyle(ZimamColor.brandInk)
                .accessibilityAddTraits(.isHeader)
            content()
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if onAccept != nil || onSecondary != nil || onDismiss != nil {
                HStack(spacing: ZimamSpacing.space2) {
                    if let onAccept {
                        Button(acceptLabel, action: onAccept).buttonStyle(.zimamPrimary)
                    }
                    if let secondaryLabel, let onSecondary {
                        Button(secondaryLabel, action: onSecondary).buttonStyle(.zimamSecondary)
                    }
                    if let onDismiss {
                        Button(dismissLabel, action: onDismiss).buttonStyle(.zimamQuiet)
                    }
                }
                .padding(.top, ZimamSpacing.space1)
            }
        }
        .padding(ZimamSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZimamColor.brandSoft, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .accessibilityElement(children: .contain)
    }
}

/// What an assistant request shows while it runs or after it fails, in the card's place.
/// Failures never block: the screen keeps working without the assistant.
struct AssistantStatus: View {
    enum Phase: Equatable {
        case loading(String)
        case failed(String)
    }

    let phase: Phase
    /// The server answered `pro_required` (only when it enforces plans): «الاشتراك» opens the
    /// paywall instead of retrying.
    var needsPro = false
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var showingPaywall = false

    var body: some View {
        switch phase {
        case .loading(let text):
            HStack(spacing: ZimamSpacing.space2) {
                ProgressView()
                Text(text)
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if needsPro || onRetry != nil || onClose != nil {
                    HStack(spacing: ZimamSpacing.space2) {
                        if needsPro {
                            Button("الاشتراك") { showingPaywall = true }.buttonStyle(.zimamPrimary)
                        } else if let onRetry {
                            Button("إعادة المحاولة", action: onRetry).buttonStyle(.zimamSecondary)
                        }
                        if let onClose {
                            Button("إغلاق", action: onClose).buttonStyle(.zimamQuiet)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        }
    }
}

/// What a failed assistant request shows: the Arabic sentence, and whether «الاشتراك» offers
/// the paywall in place of retrying (`AssistantStatus.needsPro`). The one mapping of the in-app
/// assistant's failures (the task from a sentence, the steps, the day's summary), worded as the
/// web app's (web/public/app/lib/assistant.js). `AssistantProblem` (ZimamKit) reads most of them;
/// the server's fair-use limits are read here first, since it takes any `429` for the month's
/// quota and any `503` for a provider failure.
struct AssistantFailure: Equatable {
    let message: String
    let needsPro: Bool

    init(_ error: Error, formatter: DualDateFormatter) {
        if let api = error as? APIError,
           let message = Self.limitMessage(status: api.status, code: api.code, scope: api.scope, limit: api.limit,
                                           retryAfter: api.retryAfter, locale: formatter.locale) {
            self.message = message
            needsPro = false
            return
        }
        let problem = AssistantProblem(error)
        message = problem.message(formatter: formatter)
        needsPro = problem == .proRequired
    }

    /// `429 ai_rate_limited` (or any `429` but the month's `ai_quota_exceeded`): a fair-use limit
    /// that passes on its own, per minute or, with `scope` "day", per day up to `limit`.
    /// `503 ai_busy`: the assistant has more requests than it can take right now. Both say when
    /// to try again from `retryAfter` (seconds). Nil for any other failure.
    static func limitMessage(status: Int, code: String, scope: String?, limit: Int?, retryAfter: Int?,
                             locale: Locale) -> String? {
        if code == "ai_rate_limited" || (status == 429 && code != "ai_quota_exceeded") {
            if scope == "day" {
                var text = "بلغت حد طلبات المساعد لهذا اليوم"
                if let limit {
                    text += " (الحد \(limit.formatted(.number.locale(locale))))"
                }
                // Without a time, the day's limit is back tomorrow, not «بعد قليل».
                let retry = waitText(retryAfter, locale: locale).map { "حاول بعد \($0)." } ?? "يتجدد الحد غداً."
                return "\(text). \(retry)"
            }
            return "أرسلت إلى المساعد طلبات كثيرة في وقت قصير. \(retryText(retryAfter, locale: locale))"
        }
        if code == "ai_busy" {
            return "المساعد مشغول الآن بطلبات كثيرة. \(retryText(retryAfter, locale: locale))"
        }
        return nil
    }

    /// «حاول بعد دقيقة.», or «حاول بعد قليل.» when the server did not say.
    private static func retryText(_ seconds: Int?, locale: Locale) -> String {
        waitText(seconds, locale: locale).map { "حاول بعد \($0)." } ?? "حاول بعد قليل."
    }

    /// How long to wait, from `retryAfter` in seconds: «دقيقة» up to a minute, then whole minutes
    /// («دقيقتين»، «٣ دقائق»، «١٥ دقيقة»), then whole hours («ساعة»، «ساعتين»، «٥ ساعات»), each
    /// rounded up so the request is not refused again. Nil without a usable number.
    static func waitText(_ seconds: Int?, locale: Locale) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let minutes = (seconds + 59) / 60
        if minutes < 60 {
            return count(minutes, ["دقيقة", "دقيقتين", "دقائق", "دقيقة"], locale: locale)
        }
        return count((minutes + 59) / 60, ["ساعة", "ساعتين", "ساعات", "ساعة"], locale: locale)
    }

    /// One, two, three to ten, and eleven on, after «بعد».
    private static func count(_ n: Int, _ words: [String], locale: Locale) -> String {
        let number = n.formatted(.number.locale(locale).grouping(.never))
        switch n {
        case 1: return words[0]
        case 2: return words[1]
        case 3...10: return "\(number) \(words[2])"
        default: return "\(number) \(words[3])"
        }
    }
}
