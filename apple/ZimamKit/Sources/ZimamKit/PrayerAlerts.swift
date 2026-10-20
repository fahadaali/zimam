import Foundation

/// One prayer's alerts: at the adhan, and at the iqama `iqamaMinutes` after it.
public struct PrayerAlert: Codable, Equatable, Sendable {
    public var adhan: Bool
    public var iqama: Bool
    /// Minutes from the adhan to the iqama, `PrayerAlert.iqamaRange`.
    public var iqamaMinutes: Int

    /// What the server accepts (`PrayerAlert` in api/src/data/schemas.ts).
    public static let iqamaRange: ClosedRange<Int> = 5...60

    public init(adhan: Bool = false, iqama: Bool = false, iqamaMinutes: Int) {
        self.adhan = adhan
        self.iqama = iqama
        self.iqamaMinutes = min(max(iqamaMinutes, Self.iqamaRange.lowerBound), Self.iqamaRange.upperBound)
    }

    /// Off, with the usual wait in Saudi mosques: 25 minutes at Fajr, 10 at Maghrib, 20 at the rest.
    public static func usual(for prayer: Prayer) -> PrayerAlert {
        switch prayer {
        case .fajr: PrayerAlert(iqamaMinutes: 25)
        case .maghrib: PrayerAlert(iqamaMinutes: 10)
        case .dhuhr, .asr, .isha: PrayerAlert(iqamaMinutes: 20)
        }
    }
}

/// The alerts of every prayer, stored with the account as `{ "asr": { … } }`. A prayer that is
/// missing has none, with the usual iqama wait.
public struct PrayerAlertSettings: Codable, Equatable, Sendable {
    private var alerts: [Prayer: PrayerAlert]

    public init(_ alerts: [Prayer: PrayerAlert] = [:]) {
        self.alerts = alerts
    }

    public subscript(prayer: Prayer) -> PrayerAlert {
        get { alerts[prayer] ?? .usual(for: prayer) }
        set { alerts[prayer] = newValue }
    }

    /// True when at least one prayer has an alert on.
    public var isAnyOn: Bool {
        Prayer.allCases.contains { self[$0].adhan || self[$0].iqama }
    }

    public init(from decoder: Decoder) throws {
        let raw = try [String: PrayerAlert](from: decoder)
        var alerts: [Prayer: PrayerAlert] = [:]
        for (key, alert) in raw {
            if let prayer = Prayer(rawValue: key) { alerts[prayer] = alert }
        }
        self.alerts = alerts
    }

    public func encode(to encoder: Encoder) throws {
        var raw: [String: PrayerAlert] = [:]
        for (prayer, alert) in alerts { raw[prayer.rawValue] = alert }
        try raw.encode(to: encoder)
    }
}

/// One adhan or iqama notification to schedule.
public struct PlannedPrayerAlert: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case adhan, iqama
    }

    /// Stable across runs, so rescheduling replaces rather than duplicates: "prayer-asr-adhan@2026-10-20".
    public let id: String
    public let prayer: Prayer
    public let kind: Kind
    public let date: Date
    public let title: String
    public let body: String
}

/// Chooses the adhan and iqama notifications for the next days. They share iOS's 64 pending
/// notifications with the task reminders (`ReminderPlanner`), so they take at most `limit`
/// (10 a day with everything on, so two days), and the reminders get what is left. The app
/// replans on launch, on every change, and in the background (`BackgroundRefresh`).
public enum PrayerAlertPlanner {
    public static let limit = 20
    public static let windowDays = 2

    public static let idPrefix = "prayer-"

    public static func plan(
        settings: PrayerAlertSettings,
        schedule: PrayerSchedule?,
        now: Date,
        locale: Locale = Locale(identifier: "ar-SA"),
        limit: Int = Self.limit
    ) -> [PlannedPrayerAlert] {
        guard let schedule, settings.isAnyOn else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = schedule.timeZone
        let today = calendar.startOfDay(for: now)
        var planned: [PlannedPrayerAlert] = []
        // Today and the next `windowDays` days, so the last day is whole whatever the hour.
        for offset in 0...windowDays {
            guard let start = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let noon = start.addingTimeInterval(12 * 3600)
            let times = schedule.times(on: noon)
            let c = calendar.dateComponents([.year, .month, .day], from: noon)
            let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            for prayer in Prayer.allCases {
                guard let adhan = times[prayer] else { continue }
                let alert = settings[prayer]
                if alert.adhan, adhan > now {
                    planned.append(PlannedPrayerAlert(
                        id: "\(idPrefix)\(prayer.rawValue)-adhan@\(day)", prayer: prayer, kind: .adhan, date: adhan,
                        title: "أذان \(prayer.arabicName)", body: adhanBody(prayer)))
                }
                let iqama = adhan.addingTimeInterval(TimeInterval(alert.iqamaMinutes * 60))
                if alert.iqama, iqama > now {
                    planned.append(PlannedPrayerAlert(
                        id: "\(idPrefix)\(prayer.rawValue)-iqama@\(day)", prayer: prayer, kind: .iqama, date: iqama,
                        title: "إقامة \(prayer.arabicName)",
                        body: iqamaBody(prayer, minutes: alert.iqamaMinutes, locale: locale)))
                }
            }
        }
        planned.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        return Array(planned.prefix(max(0, limit)))
    }

    /// «حان الآن وقت صلاة العصر».
    static func adhanBody(_ prayer: Prayer) -> String {
        "حان الآن وقت صلاة \(prayer.arabicName)"
    }

    /// «حان وقت إقامة صلاة العصر، بعد الأذان بـ٢٠ دقيقة».
    static func iqamaBody(_ prayer: Prayer, minutes: Int, locale: Locale) -> String {
        let number = minutes.formatted(.number.locale(locale).grouping(.never))
        return "حان وقت إقامة صلاة \(prayer.arabicName)، بعد الأذان بـ\(number) دقيقة"
    }
}
