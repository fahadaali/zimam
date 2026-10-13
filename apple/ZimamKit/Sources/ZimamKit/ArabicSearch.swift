import Foundation

/// Folds Arabic text for search, matching the API: no diacritics or tatweel,
/// one alef, taa marbuta as haa, alef maqsura as yaa, Latin digits.
public enum ArabicSearch {
    public static func fold(_ text: String) -> String {
        var result = ""
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x06D6...0x06ED, 0x0640:
                continue
            case 0x0622, 0x0623, 0x0625, 0x0671:
                result.unicodeScalars.append("\u{0627}")
            case 0x0629:
                result.unicodeScalars.append("\u{0647}")
            case 0x0649:
                result.unicodeScalars.append("\u{064A}")
            case 0x0660...0x0669:
                result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9:
                result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether every word of `query` appears in `text`, after folding.
    public static func matches(_ text: String, query: String) -> Bool {
        let haystack = fold(text)
        let words = fold(query).split(separator: " ")
        return !words.isEmpty && words.allSatisfy { haystack.contains($0) }
    }
}
