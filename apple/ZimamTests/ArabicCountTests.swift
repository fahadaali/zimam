import Foundation
import Testing
@testable import Zimam

/// Counted minutes in «أوقات الصلاة»: «دقائق» from three to ten, «دقيقة» from eleven on. Latin digits
/// so the test doesn't depend on the system's Arabic numbering.
@MainActor
struct ArabicCountTests {
    let locale = Locale(identifier: "en_US_POSIX")

    @Test func minutesTakeThePluralFromThreeToTen() {
        #expect(ArabicCount.minutes(5, locale: locale) == "5 دقائق")
        #expect(ArabicCount.minutes(10, locale: locale) == "10 دقائق")
    }

    @Test func minutesTakeTheSingularFromElevenOn() {
        #expect(ArabicCount.minutes(15, locale: locale) == "15 دقيقة")
        #expect(ArabicCount.minutes(60, locale: locale) == "60 دقيقة")
    }
}
