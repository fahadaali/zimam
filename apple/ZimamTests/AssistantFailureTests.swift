import Foundation
import Testing
@testable import Zimam

/// The assistant's fair-use limits and the account deletion's refusals, in Arabic
/// (Zimam/Components/AssistantSuggestion.swift, Zimam/App/SessionStore.swift). Latin digits so
/// the test doesn't depend on the system's Arabic numbering.
@MainActor
struct AssistantFailureTests {
    let locale = Locale(identifier: "en_US_POSIX")

    @Test func minuteLimitSaysWhenToTryAgain() {
        let message = AssistantFailure.limitMessage(status: 429, code: "ai_rate_limited", scope: "minute", limit: 10,
                                                    retryAfter: 42, locale: locale)
        #expect(message == "أرسلت إلى المساعد طلبات كثيرة في وقت قصير. حاول بعد دقيقة.")
    }

    @Test func dayLimitNamesTheLimitAndTheWait() {
        let message = AssistantFailure.limitMessage(status: 429, code: "ai_rate_limited", scope: "day", limit: 50,
                                                    retryAfter: 5 * 3600 - 10, locale: locale)
        #expect(message == "بلغت حد طلبات المساعد لهذا اليوم (الحد 50). حاول بعد 5 ساعات.")
        let bare = AssistantFailure.limitMessage(status: 429, code: "ai_rate_limited", scope: "day", limit: nil,
                                                 retryAfter: nil, locale: locale)
        #expect(bare == "بلغت حد طلبات المساعد لهذا اليوم. يتجدد الحد غداً.")
    }

    @Test func busyAssistantAsksToWait() {
        let message = AssistantFailure.limitMessage(status: 503, code: "ai_busy", scope: nil, limit: nil,
                                                    retryAfter: nil, locale: locale)
        #expect(message == "المساعد مشغول الآن بطلبات كثيرة. حاول بعد قليل.")
    }

    @Test func monthQuotaAndOtherFailuresAreLeftToAssistantProblem() {
        #expect(AssistantFailure.limitMessage(status: 429, code: "ai_quota_exceeded", scope: nil, limit: 300,
                                              retryAfter: nil, locale: locale) == nil)
        #expect(AssistantFailure.limitMessage(status: 403, code: "pro_required", scope: nil, limit: nil,
                                              retryAfter: nil, locale: locale) == nil)
        #expect(AssistantFailure.limitMessage(status: 503, code: "ai_unavailable", scope: nil, limit: nil,
                                              retryAfter: nil, locale: locale) == nil)
    }

    @Test func waitRoundsUpToMinutesThenHours() {
        #expect(AssistantFailure.waitText(nil, locale: locale) == nil)
        #expect(AssistantFailure.waitText(0, locale: locale) == nil)
        #expect(AssistantFailure.waitText(60, locale: locale) == "دقيقة")
        #expect(AssistantFailure.waitText(61, locale: locale) == "دقيقتين")
        #expect(AssistantFailure.waitText(5 * 60, locale: locale) == "5 دقائق")
        #expect(AssistantFailure.waitText(15 * 60, locale: locale) == "15 دقيقة")
        #expect(AssistantFailure.waitText(3600, locale: locale) == "ساعة")
        #expect(AssistantFailure.waitText(11 * 3600, locale: locale) == "11 ساعة")
    }

    @Test func deletionRefusalsSayWhatToDo() {
        #expect(SessionStore.deletionMessage(code: "reauth_mismatch").hasPrefix("سجّلت الدخول بحساب غير هذا الحساب"))
        #expect(SessionStore.deletionMessage(code: "reauth_required").hasPrefix("لم يتأكد زمام من هويتك"))
        #expect(SessionStore.deletionMessage(code: nil) == "تعذّر حذف الحساب. تحقّق من الاتصال وحاول مرة أخرى.")
    }
}
