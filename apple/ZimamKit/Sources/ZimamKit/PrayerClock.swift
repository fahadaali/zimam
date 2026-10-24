import Foundation

/// What the prayer screen, widgets and complications show at a moment: the time left until
/// the next prayer, or, for half an hour after an adhan, the time since it.
public struct PrayerClock: Sendable {
    public enum State: Equatable, Sendable {
        /// Within `elapsedWindow` after this prayer's adhan: «مضى على أذان العصر ١٢:٠٣».
        case since(Prayer, adhan: Date)
        /// Counting down to this prayer: «العصر بعد ١:١٢:٠٥».
        case until(Prayer, time: Date)

        public var prayer: Prayer {
            switch self {
            case .since(let prayer, _), .until(let prayer, _): prayer
            }
        }

        /// The adhan the state counts from or to.
        public var time: Date {
            switch self {
            case .since(_, let adhan): adhan
            case .until(_, let time): time
            }
        }

        /// «المتبقي على العصر» or «مضى على أذان العصر»: the line above the countdown, the same on
        /// the app's prayer card, the widgets, the Lock Screen and the watch.
        public var title: String {
            switch self {
            case .since(let prayer, _): "مضى على أذان \(prayer.arabicName)"
            case .until(let prayer, _): "المتبقي على \(prayer.arabicName)"
            }
        }
    }

    /// How long after the adhan the clock counts up before moving on to the next prayer.
    public static let elapsedWindow: TimeInterval = 30 * 60

    public let schedule: PrayerSchedule

    public init(schedule: PrayerSchedule) {
        self.schedule = schedule
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = schedule.timeZone
        return calendar
    }

    /// Adhans from the day before `date` to `days` days after it, in order.
    private func adhans(around date: Date, days: Int) -> [(prayer: Prayer, time: Date)] {
        let today = calendar.startOfDay(for: date)
        var result: [(prayer: Prayer, time: Date)] = []
        for offset in -1...max(1, days) {
            guard let start = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let times = schedule.times(on: start.addingTimeInterval(12 * 3600))
            for prayer in Prayer.allCases {
                if let time = times[prayer] { result.append((prayer: prayer, time: time)) }
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    public func state(at date: Date) -> State? {
        let all = adhans(around: date, days: 1)
        if let last = all.last(where: { $0.time <= date }), date.timeIntervalSince(last.time) < Self.elapsedWindow {
            return .since(last.prayer, adhan: last.time)
        }
        return all.first(where: { $0.time > date }).map { State.until($0.prayer, time: $0.time) }
    }

    /// The next `count` adhans after `date`, past midnight into the next days.
    public func upcoming(after date: Date, count: Int) -> [(prayer: Prayer, time: Date)] {
        Array(adhans(around: date, days: max(1, count / Prayer.allCases.count + 1)).filter { $0.time > date }.prefix(count))
    }

    /// The moments the state changes in the next `days` days, for widget timelines: each adhan,
    /// half an hour after each, and each midnight (the day's list changes).
    public func changes(from date: Date, days: Int) -> [Date] {
        let end = date.addingTimeInterval(TimeInterval(days) * 86_400)
        var moments: [Date] = []
        for adhan in adhans(around: date, days: days) {
            moments.append(adhan.time)
            moments.append(adhan.time.addingTimeInterval(Self.elapsedWindow))
        }
        let today = calendar.startOfDay(for: date)
        for offset in 1...max(1, days) {
            if let midnight = calendar.date(byAdding: .day, value: offset, to: today) { moments.append(midnight) }
        }
        return Array(Set(moments.filter { $0 > date && $0 <= end })).sorted()
    }
}
