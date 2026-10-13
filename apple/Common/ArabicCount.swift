import Foundation

/// Counted nouns in Arabic, which change with the number: «مهمة واحدة»، «مهمتان»، «٣ مهام»، «١١ مهمة».
enum ArabicCount {
    static func tasks(_ count: Int, locale: Locale) -> String {
        let number = count.formatted(.number.locale(locale))
        switch count {
        case 0: return "لا مهام"
        case 1: return "مهمة واحدة"
        case 2: return "مهمتان"
        case 3...10: return "\(number) مهام"
        default: return "\(number) مهمة"
        }
    }
}
