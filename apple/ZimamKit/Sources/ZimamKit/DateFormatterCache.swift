import Foundation
import Synchronization

/// One `DateFormatter` per calendar, locale, time zone and pattern, made once and reused.
/// Rows format their dates on every render, and making a DateFormatter costs far more than
/// using one. `DateFormatter` is not Sendable, so formatting happens under the lock.
enum DateFormatterCache {
    private struct Key: Hashable {
        /// nil: the locale's own calendar.
        let calendar: Calendar.Identifier?
        let locale: Locale
        let timeZone: TimeZone
        /// nil: the locale's short time («٣:٠٠ م»).
        let pattern: String?
    }

    private static let formatters = Mutex<[Key: DateFormatter]>([:])

    /// `date` with `pattern` in `calendar`; with no pattern, the locale's short time.
    static func string(
        from date: Date, calendar: Calendar.Identifier?, locale: Locale, timeZone: TimeZone, pattern: String?
    ) -> String {
        let key = Key(calendar: calendar, locale: locale, timeZone: timeZone, pattern: pattern)
        return formatters.withLock { cache in
            if let formatter = cache[key] { return formatter.string(from: date) }
            let formatter = DateFormatter()
            if let identifier = key.calendar {
                var calendar = Calendar(identifier: identifier)
                calendar.timeZone = timeZone
                formatter.calendar = calendar
            }
            formatter.locale = locale
            formatter.timeZone = timeZone
            if let pattern {
                formatter.dateFormat = pattern
            } else {
                formatter.dateStyle = .none
                formatter.timeStyle = .short
            }
            cache[key] = formatter
            return formatter.string(from: date)
        }
    }
}
