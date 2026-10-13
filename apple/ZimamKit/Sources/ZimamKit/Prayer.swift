import Adhan
import Foundation

/// The five daily prayers, with the raw values the API uses.
public enum Prayer: String, CaseIterable, Codable, Sendable {
    case fajr, dhuhr, asr, maghrib, isha

    public var arabicName: String {
        switch self {
        case .fajr: "الفجر"
        case .dhuhr: "الظهر"
        case .asr: "العصر"
        case .maghrib: "المغرب"
        case .isha: "العشاء"
        }
    }
}

/// Calculation methods offered in settings, with the raw values the API stores.
public enum PrayerMethod: String, CaseIterable, Codable, Sendable {
    case ummAlQura, muslimWorldLeague, egyptian, karachi, dubai, kuwait, qatar, northAmerica

    public var arabicName: String {
        switch self {
        case .ummAlQura: "أم القرى"
        case .muslimWorldLeague: "رابطة العالم الإسلامي"
        case .egyptian: "الهيئة المصرية العامة للمساحة"
        case .karachi: "جامعة العلوم الإسلامية بكراتشي"
        case .dubai: "دبي"
        case .kuwait: "الكويت"
        case .qatar: "قطر"
        case .northAmerica: "الجمعية الإسلامية لأمريكا الشمالية"
        }
    }

    var adhanMethod: CalculationMethod {
        switch self {
        case .ummAlQura: .ummAlQura
        case .muslimWorldLeague: .muslimWorldLeague
        case .egyptian: .egyptian
        case .karachi: .karachi
        case .dubai: .dubai
        case .kuwait: .kuwait
        case .qatar: .qatar
        case .northAmerica: .northAmerica
        }
    }
}

/// Prayer times for one place, computed on the device without a network.
public struct PrayerSchedule: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let method: PrayerMethod
    public let timeZone: TimeZone

    public init(latitude: Double, longitude: Double, method: PrayerMethod = .ummAlQura, timeZone: TimeZone = .current) {
        self.latitude = latitude
        self.longitude = longitude
        self.method = method
        self.timeZone = timeZone
    }

    private var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The times of the five prayers on the local day that contains `day`.
    public func times(on day: Date) -> [Prayer: Date] {
        let components = gregorian.dateComponents([.year, .month, .day], from: day)
        var parameters = method.adhanMethod.params
        // Umm al-Qura sets Isha 120 minutes after Maghrib in Ramadan instead of 90.
        if method == .ummAlQura, Self.isRamadan(day, timeZone: timeZone) {
            parameters.ishaInterval = 120
        }
        let coordinates = Coordinates(latitude: latitude, longitude: longitude)
        guard let times = PrayerTimes(coordinates: coordinates, date: components, calculationParameters: parameters) else {
            return [:]
        }
        return [.fajr: times.fajr, .dhuhr: times.dhuhr, .asr: times.asr, .maghrib: times.maghrib, .isha: times.isha]
    }

    /// When a prayer-anchored task or reminder falls on that day.
    public func time(of prayer: Prayer, on day: Date, offsetMinutes: Int = 0) -> Date? {
        times(on: day)[prayer].map { $0.addingTimeInterval(TimeInterval(offsetMinutes * 60)) }
    }

    /// The first prayer after `date`, looking into the next day if needed.
    public func next(after date: Date) -> (prayer: Prayer, time: Date)? {
        for dayOffset in 0...1 {
            guard let day = gregorian.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let times = times(on: day)
            for prayer in Prayer.allCases {
                if let time = times[prayer], time > date { return (prayer, time) }
            }
        }
        return nil
    }

    static func isRamadan(_ date: Date, timeZone: TimeZone) -> Bool {
        var hijri = Calendar(identifier: .islamicUmmAlQura)
        hijri.timeZone = timeZone
        return hijri.component(.month, from: date) == 9
    }
}
