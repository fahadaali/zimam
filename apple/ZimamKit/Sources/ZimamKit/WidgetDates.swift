import Foundation

// Short date texts for the widgets, where a whole title does not fit on one line.

extension DualDateFormatter {
    /// A month grid's title in two parts, for two lines or two sizes: the month in `kind` with its
    /// year, and the months of the other calendar it spans. Together they read as `monthTitle`.
    /// («جمادى الأولى ١٤٤٨هـ», «أكتوبر – نوفمبر ٢٠٢٦م»).
    public func monthTitleParts(_ date: Date, in kind: CalendarKind) -> (primary: String, other: String) {
        var calendar = Calendar(identifier: kind.identifier)
        calendar.timeZone = timeZone
        guard let month = calendar.dateInterval(of: .month, for: date),
              let last = calendar.date(byAdding: .day, value: -1, to: month.end) else { return ("", "") }
        return (monthYear(month.start, in: kind), monthSpan(from: month.start, to: last, in: kind.other))
    }

    /// The month's name in `kind`: «جمادى الأولى», «أكتوبر».
    public func monthName(_ date: Date, in kind: CalendarKind) -> String {
        formatted(date, in: kind, pattern: "MMMM")
    }

    /// The year with its suffix: «١٤٤٨هـ», «٢٠٢٦م».
    public func yearTitle(_ date: Date, in kind: CalendarKind) -> String {
        "\(formatted(date, in: kind, pattern: "y"))\(kind.yearSuffix)"
    }

    /// A clock time in 24 hours, short enough for a narrow day column: «١٦:٤٢», «٨:٠٥».
    public func compactTime(_ date: Date) -> String {
        formatted(date, in: .gregorian, pattern: "H:mm")
    }

    private func formatted(_ date: Date, in kind: CalendarKind, pattern: String) -> String {
        DateFormatterCache.string(from: date, calendar: kind.identifier, locale: locale, timeZone: timeZone, pattern: pattern)
    }
}

/// Counted days in Arabic, which change with the number: «يوم واحد»، «يومان»، «٣ أيام»،
/// «١١ يوماً»، «١٠٠ يوم».
public enum ArabicDays {
    public static func count(_ count: Int, locale: Locale) -> String {
        let number = count.formatted(.number.locale(locale).grouping(.never))
        switch count {
        case 0: return "لا أيام"
        case 1: return "يوم واحد"
        case 2: return "يومان"
        case 3...10: return "\(number) أيام"
        case 11...99: return "\(number) يوماً"
        default:
            // Past a hundred the last two digits decide: «١٠٠ يوم»، «١٠٢ يوم»، «١٠٣ أيام»، «١١١ يوماً».
            switch count % 100 {
            case 3...10: return "\(number) أيام"
            case 11...99: return "\(number) يوماً"
            default: return "\(number) يوم"
            }
        }
    }
}
