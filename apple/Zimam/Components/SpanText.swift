import Foundation
import ZimamKit

extension ArabicCount {
    /// «يوم واحد»، «يومان»، «٣ أيام»، «١١ يوماً»، «١٠٠ يوم».
    static func days(_ count: Int, locale: Locale) -> String {
        let number = count.formatted(.number.locale(locale))
        switch count {
        case 1: return "يوم واحد"
        case 2: return "يومان"
        default:
            switch count % 100 {
            case 3...10: return "\(number) أيام"
            case 11...99: return "\(number) يوماً"
            default: return "\(number) يوم"
            }
        }
    }
}

extension DualDateFormatter {
    /// A span in words for labels and VoiceOver, both calendars in each date with the user's primary
    /// one first: «من ٢٨ ربيع الآخر، ٩ أكتوبر إلى ٣٠ ربيع الآخر، ١١ أكتوبر، ٣ أيام». One day reads as that day.
    func spanText(_ span: DaySpan) -> String {
        guard let end = date(fromDay: span.end) else { return "" }
        guard span.isMultiDay, let start = date(fromDay: span.start) else { return dual(end) }
        return "من \(dual(start)) إلى \(dual(end))، \(ArabicCount.days(span.dayCount, locale: locale))"
    }
}
