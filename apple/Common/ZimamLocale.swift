import Foundation

nonisolated enum ZimamLocale {
    /// Arabic formats with the digits the user chose in system settings
    /// (Arabic-Indic by default for Arabic).
    static var current: Locale {
        Locale(identifier: "ar_SA@numbers=\(Locale.current.numberingSystem.identifier)")
    }
}
