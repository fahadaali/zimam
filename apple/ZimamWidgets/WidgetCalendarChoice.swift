import AppIntents
import ZimamKit

// MARK: Calendar choice

/// Which calendar a configurable widget uses: the user's own (settings), Hijri or Gregorian.
enum WidgetCalendarChoice: String, AppEnum {
    case automatic, hijri, gregorian

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "التقويم"
    static let caseDisplayRepresentations: [WidgetCalendarChoice: DisplayRepresentation] = [
        .automatic: "تقويمك في الإعدادات",
        .hijri: "الهجري",
        .gregorian: "الميلادي",
    ]

    func kind(default fallback: CalendarKind) -> CalendarKind {
        switch self {
        case .automatic: fallback
        case .hijri: .hijri
        case .gregorian: .gregorian
        }
    }
}
