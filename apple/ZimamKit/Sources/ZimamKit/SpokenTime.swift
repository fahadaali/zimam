import Foundation

/// The time in a sentence said or written in Arabic, read on the device: «ذكرني أراجع العقد قبل
/// المغرب بربع ساعة بكرة», «اتصل بأحمد الخميس الساعة ٥ العصر», «أشتري خبز بعد ساعتين». It is
/// what Zimam uses when the assistant cannot read the sentence (offline, signed out, without the
/// plan or its quota) and for reminders brought over from Apple Reminders, so a spoken time is
/// not lost with the assistant. The rules match the assistant's (api/src/ai/prompts.ts):
///
/// - A prayer after قبل، بعد، عند، مع or وقت, with «صلاة» or without, and a duration before or
///   after it: «بعد العصر بنص ساعة» = +30, «قبل الفجر بربع ساعة» = −15. «قبل X» alone is
///   `defaultBeforeMinutes` before it. «صلاة الجمعة» is Dhuhr on Friday. «بين المغرب والعشاء» is
///   half an hour after Maghrib, «آخر الليل» an hour before Fajr.
/// - Days: اليوم، الليلة، بكرة، بعد بكرة، «بعد ٣ أيام»، a weekday (its next date after today),
///   «الأسبوع الجاي».
/// - A clock time: «الساعة ٥», «٥:٣٠», «٥ ونص», «٥ إلا ربع», with or without a period
///   («العصر», «الصبح», «المساء»…); without one, the reading between 07:00 and 22:59.
/// - Parts of the day: الصبح ٠٩:٠٠، الضحى ٠٩:٣٠، العصرية ١٦:٣٠، المساء ١٨:٠٠، الليل ٢١:٠٠،
///   قبل النوم ٢٢:٠٠.
/// - From now: «بعد ساعتين», «بعد ٢٠ دقيقة».
///
/// What is read leaves the title, with the reminder words («ذكرني»). A task gets a prayer or a
/// clock time, never both; a prayer or a time without a day is today, or tomorrow once it has
/// passed today (for a prayer, when the place is known).
public enum SpokenTime {
    /// «قبل المغرب» without a duration: a reminder a quarter of an hour before the adhan.
    public static let defaultBeforeMinutes = 15

    public struct Reading: Equatable, Sendable {
        public var title: String
        /// "2026-10-15".
        public var dueDate: String?
        /// "HH:mm", only without a prayer.
        public var dueTime: String?
        public var duePrayer: Prayer?
        /// Minutes after (positive) or before (negative) the prayer.
        public var duePrayerOffset: Int?

        public init(title: String, dueDate: String? = nil, dueTime: String? = nil, duePrayer: Prayer? = nil,
                    duePrayerOffset: Int? = nil) {
            self.title = title
            self.dueDate = dueDate
            self.dueTime = dueTime
            self.duePrayer = duePrayer
            self.duePrayerOffset = duePrayerOffset
        }

        /// Whether the sentence named a day, a time or a prayer.
        public var hasWhen: Bool { dueDate != nil || dueTime != nil || duePrayer != nil }
    }

    /// Reads `text` at `now` in `timeZone`. `schedule` (the user's place) tells whether a prayer
    /// named without a day has passed today; without it such a prayer is today.
    public static func read(_ text: String, now: Date = Date(), timeZone: TimeZone = .current,
                            schedule: PrayerSchedule? = nil) -> Reading {
        var parser = Parser(text)
        parser.readAll()
        return parser.resolve(now: now, timeZone: timeZone, schedule: schedule)
    }

    // MARK: Words

    /// Without diacritics and tatweel, with one form of alef, taa marbuta as haa, alef maqsura as
    /// yaa, Latin digits, and no punctuation at either end.
    static func normalize(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x0652, 0x0670, 0x0640:
                continue
            case 0x0660...0x0669:
                out.append(Unicode.Scalar(UInt8(48 + scalar.value - 0x0660)))
            case 0x06F0...0x06F9:
                out.append(Unicode.Scalar(UInt8(48 + scalar.value - 0x06F0)))
            case 0x0622, 0x0623, 0x0625:
                out.append(contentsOf: "ا".unicodeScalars)
            case 0x0629:
                out.append(contentsOf: "ه".unicodeScalars)
            case 0x0649:
                out.append(contentsOf: "ي".unicodeScalars)
            default:
                out.append(scalar)
            }
        }
        return String(out).trimmingCharacters(in: CharacterSet(charactersIn: "،,.؟?!؛;\"«»()[]-"))
    }

    static let prayers: [String: Prayer] = [
        "الفجر": .fajr, "الظهر": .dhuhr, "العصر": .asr, "المغرب": .maghrib, "العشاء": .isha, "العشا": .isha,
    ]
    static let friday = "الجمعه"
    static let relations: [String: Relation] = ["قبل": .before, "بعد": .after, "عند": .at, "مع": .at, "وقت": .at]

    enum Relation { case before, after, at }

    static let numbers: [String: Int] = [
        "واحد": 1, "وحده": 1, "اثنين": 2, "اثنتين": 2, "ثنتين": 2, "ثلاث": 3, "ثلاثه": 3, "اربع": 4, "اربعه": 4,
        "خمس": 5, "خمسه": 5, "ست": 6, "سته": 6, "سبع": 7, "سبعه": 7, "ثمان": 8, "ثمانيه": 8, "تسع": 9, "تسعه": 9,
        "عشر": 10, "عشره": 10, "احدعش": 11, "احدعشر": 11, "اثنعش": 12, "اثنعشر": 12, "خمسطعش": 15, "خمستعش": 15,
        "عشرين": 20, "ثلاثين": 30, "اربعين": 40, "خمسين": 50,
    ]
    static let fractions: [String: Int] = ["ربع": 15, "نص": 30, "نصف": 30, "ثلث": 20]
    static let minuteUnits: Set<String> = ["دقيقه", "دقائق", "دقايق", "د", "دقيقا"]
    static let hourUnits: Set<String> = ["ساعه", "ساعات", "س"]
    static let dayUnits: Set<String> = ["يوم", "ايام"]

    static let weekdays: [String: Int] = [
        "الاحد": 1, "الاثنين": 2, "الثلاثاء": 3, "الثلاثا": 3, "الاربعاء": 4, "الاربعا": 4, "الخميس": 5,
        "الجمعه": 6, "السبت": 7,
    ]
    static let nextWords: Set<String> = ["الجاي", "الجايه", "القادم", "القادمه", "الياي"]
    static let tomorrowWords: Set<String> = ["بكره", "بكرا", "غدا", "باكر", "الغد"]

    /// Period words after a clock time, as the hour they put it in.
    enum Period { case morning, noon, evening, night }
    static let periods: [String: Period] = [
        "الصبح": .morning, "الصباح": .morning, "صباحا": .morning, "ص": .morning, "الفجر": .morning,
        "الظهر": .noon, "الظهريه": .noon,
        "العصر": .evening, "العصريه": .evening, "المغرب": .evening, "المسا": .evening, "المساء": .evening,
        "مساء": .evening, "مساءا": .evening, "م": .evening,
        "الليل": .night, "بالليل": .night, "الليله": .night,
    ]
    /// Parts of the day on their own, as a time.
    static let partsOfDay: [String: (hour: Int, minute: Int)] = [
        "الصبح": (9, 0), "الصباح": (9, 0), "صباحا": (9, 0), "الضحي": (9, 30), "العصريه": (16, 30),
        "المسا": (18, 0), "المساء": (18, 0), "مساء": (18, 0), "الليل": (21, 0), "بالليل": (21, 0),
    ]
    static let reminderWords: Set<String> = ["ذكرني", "ذكريني", "ذكرنا", "فكرني", "نبهني", "تذكير", "ذكر"]
    /// Words that only joined a time to the rest, left hanging at either end once the time is read.
    static let connectors: Set<String> = [
        "في", "على", "يوم", "و", "الساعه", "بعد", "قبل", "عند", "من", "الي", "مع", "ان", "اني", "لي", "ب",
    ]

    // MARK: Parser

    struct Parser {
        let words: [String]
        let keys: [String]
        var used: [Bool]

        var dayOffset: Int?
        var weekday: Int?
        var nextWeek = false
        var prayer: Prayer?
        var prayerOffset: Int?
        var isFriday = false
        var clock: (hour: Int, minute: Int)?
        var partOfDay: (hour: Int, minute: Int)?
        var fromNow: Int?

        init(_ text: String) {
            words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            keys = words.map(SpokenTime.normalize)
            used = Array(repeating: false, count: words.count)
        }

        var count: Int { keys.count }

        func key(_ i: Int) -> String? {
            i >= 0 && i < count && !used[i] ? keys[i] : nil
        }

        /// The key without a leading «و» when the rest is a word this reader knows («وبعد»).
        func bare(_ i: Int, in known: (String) -> Bool) -> String? {
            guard let k = key(i) else { return nil }
            if known(k) { return k }
            if k.hasPrefix("و"), k.count > 1 {
                let rest = String(k.dropFirst())
                if known(rest) { return rest }
            }
            return nil
        }

        mutating func use(_ range: Range<Int>) {
            for i in range where i >= 0 && i < count { used[i] = true }
        }

        mutating func readAll() {
            readSpecialPhrases()
            readClock()
            readPrayers()
            readFromNow()
            readDays()
            readPartsOfDay()
        }

        // MARK: Numbers and durations

        static func number(_ k: String) -> Int? {
            if !k.isEmpty, k.allSatisfy({ $0.isASCII && $0.isNumber }) { return Int(k) }
            if let n = SpokenTime.numbers[k] { return n }
            if k.hasPrefix("ال"), let n = SpokenTime.numbers[String(k.dropFirst(2))] { return n }
            return nil
        }

        /// «ونص», «وربع», «و نص» after an hour, as minutes and the words they take.
        func extraMinutes(at i: Int) -> (minutes: Int, length: Int) {
            guard let k = key(i) else { return (0, 0) }
            if k == "ونص" || k == "ونصف" { return (30, 1) }
            if k == "وربع" { return (15, 1) }
            if k == "وثلث" { return (20, 1) }
            if k == "و", let next = key(i + 1), let f = SpokenTime.fractions[next] { return (f, 2) }
            return (0, 0)
        }

        /// A duration starting at `i`: «ربع ساعة», «نص ساعة», «ساعة», «ساعتين ونص», «٢٠ دقيقة»,
        /// «عشر دقايق», with «ب» before it or joined to it («بربع», «بـ٢٠») when `withB`.
        /// `bareNumbers` reads a lone number as minutes («بعد العصر بعشر»).
        func duration(at i: Int, withB: Bool, bareNumbers: Bool = false) -> (minutes: Int, length: Int)? {
            guard var k = key(i) else { return nil }
            if withB {
                if k == "ب" {
                    guard let rest = duration(at: i + 1, withB: false, bareNumbers: bareNumbers) else { return nil }
                    return (rest.minutes, rest.length + 1)
                }
                if k.hasPrefix("ب"), k.count > 1 {
                    let rest = String(k.dropFirst())
                    if Self.isDurationHead(rest) { k = rest } else if !Self.isDurationHead(k) { return nil }
                }
            }
            if k == "ساعتين" {
                let extra = extraMinutes(at: i + 1)
                return (120 + extra.minutes, 1 + extra.length)
            }
            if k == "ساعه" {
                let extra = extraMinutes(at: i + 1)
                return (60 + extra.minutes, 1 + extra.length)
            }
            if k == "دقيقتين" { return (2, 1) }
            if let f = SpokenTime.fractions[k] {
                if let next = key(i + 1), SpokenTime.hourUnits.contains(next) { return (f, 2) }
                return (f, 1)
            }
            if let n = Self.number(k) {
                if let unit = key(i + 1) {
                    if SpokenTime.minuteUnits.contains(unit) { return (n, 2) }
                    if SpokenTime.hourUnits.contains(unit) {
                        let extra = extraMinutes(at: i + 2)
                        return (n * 60 + extra.minutes, 2 + extra.length)
                    }
                }
                if bareNumbers, n > 0, n < 180 { return (n, 1) }
            }
            return nil
        }

        static func isDurationHead(_ k: String) -> Bool {
            k == "ساعه" || k == "ساعتين" || k == "دقيقتين" || SpokenTime.fractions[k] != nil || number(k) != nil
        }

        // MARK: Passes

        /// «بين المغرب والعشاء», «آخر الليل», «قبل النوم».
        mutating func readSpecialPhrases() {
            for i in 0..<count {
                guard let k = key(i) else { continue }
                if k == "بين", key(i + 1) == "المغرب",
                   let next = key(i + 2), next == "والعشاء" || next == "والعشا" {
                    prayer = .maghrib
                    prayerOffset = 30
                    use(i..<(i + 3))
                } else if k == "اخر", key(i + 1) == "الليل" {
                    prayer = .fajr
                    prayerOffset = -60
                    use(i..<(i + 2))
                } else if k == "قبل", key(i + 1) == "النوم" {
                    partOfDay = (22, 0)
                    use(i..<(i + 2))
                }
            }
        }

        /// «الساعة ٥ ونص العصر», «٥:٣٠», «٩ الصبح», «الساعة ٥ إلا ربع».
        mutating func readClock() {
            var i = 0
            while i < count {
                defer { i += 1 }
                guard let k = key(i) else { continue }
                let anchored = k == "الساعه"
                let start = anchored ? i + 1 : i
                guard let head = key(start) else { continue }
                var hour: Int?
                var minute = 0
                if head.contains(":") {
                    let parts = head.split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2 { hour = parts[0]; minute = parts[1] }
                } else {
                    hour = Self.number(head)
                }
                guard var h = hour, (0...23).contains(h), (0...59).contains(minute) else { continue }
                var end = start + 1
                let extra = extraMinutes(at: end)
                if extra.length > 0 {
                    minute = extra.minutes
                    end += extra.length
                } else if key(end) == "الا", let f = key(end + 1).flatMap({ SpokenTime.fractions[$0] }) {
                    // «٥ إلا ربع» is 4:45.
                    h = (h + 23) % 24
                    minute = 60 - f
                    end += 2
                }
                var period: Period?
                if let p = key(end).flatMap({ SpokenTime.periods[$0] }) {
                    period = p
                    end += 1
                }
                // A number alone is a clock time only after «الساعة» or before a period.
                guard anchored || period != nil else { continue }
                clock = (Self.hour24(h, period: period), minute)
                use(i..<end)
                i = end - 1
            }
        }

        static func hour24(_ h: Int, period: Period?) -> Int {
            if h > 12 { return h }
            switch period {
            case .morning?: return h == 12 ? 0 : h
            case .noon?: return (1...6).contains(h) ? h + 12 : h
            case .evening?: return h < 12 ? h + 12 : h
            case .night?: return h == 12 ? 0 : (h < 5 ? h : h + 12)
            case nil: return (1...6).contains(h) ? h + 12 : h
            }
        }

        /// «قبل المغرب بربع ساعة», «بعد صلاة العصر», «بنص ساعة بعد العشاء», «صلاة الجمعة».
        mutating func readPrayers() {
            for i in 0..<count {
                guard prayer == nil else { return }
                guard let k = key(i) else { continue }
                var relation: Relation?
                var nameAt = i
                if let r = bare(i, in: { SpokenTime.relations[$0] != nil }) {
                    relation = SpokenTime.relations[r]
                    nameAt = i + 1
                    if key(nameAt) == "صلاه" { nameAt += 1 }
                } else if k == "صلاه" || k == "وصلاه" {
                    relation = .at
                    nameAt = i + 1
                } else {
                    continue
                }
                guard let relation, let name = key(nameAt) else { continue }
                let found: Prayer
                if let p = SpokenTime.prayers[name] {
                    found = p
                } else if name == SpokenTime.friday, relation != .at || k.hasSuffix("صلاه") {
                    found = .dhuhr
                    isFriday = true
                } else {
                    continue
                }
                var start = i
                var end = nameAt + 1
                var minutes: Int?
                if let after = duration(at: end, withB: true, bareNumbers: true) {
                    minutes = after.minutes
                    end += after.length
                } else {
                    // «بنص ساعة قبل المغرب»: the duration just before the relation, longest first
                    // («بنص ساعة» rather than «ساعة»).
                    for length in stride(from: 3, through: 1, by: -1) where i - length >= 0 {
                        if let before = duration(at: i - length, withB: true), before.length == length {
                            minutes = before.minutes
                            start = i - length
                            break
                        }
                    }
                }
                switch relation {
                case .before: prayerOffset = -(minutes ?? SpokenTime.defaultBeforeMinutes)
                case .after, .at: prayerOffset = minutes ?? 0
                }
                prayer = found
                use(start..<end)
            }
        }

        /// «بعد ساعتين», «بعد ٢٠ دقيقة», «بعد ٣ أيام», «بعد يومين», «بعد أسبوع».
        mutating func readFromNow() {
            for i in 0..<count {
                guard let k = bare(i, in: { $0 == "بعد" }), k == "بعد" else { continue }
                if key(i + 1) == "يومين" {
                    dayOffset = 2
                    use(i..<(i + 2))
                } else if key(i + 1) == "اسبوع" {
                    dayOffset = 7
                    use(i..<(i + 2))
                } else if let n = key(i + 1).flatMap(Self.number), let unit = key(i + 2), SpokenTime.dayUnits.contains(unit) {
                    dayOffset = n
                    use(i..<(i + 3))
                } else if let span = duration(at: i + 1, withB: false) {
                    fromNow = span.minutes
                    use(i..<(i + 1 + span.length))
                }
            }
        }

        /// اليوم، الليلة، بكرة، بعد بكرة، a weekday, «الأسبوع الجاي».
        mutating func readDays() {
            for i in 0..<count {
                guard let k = key(i) else { continue }
                if SpokenTime.tomorrowWords.contains(k) || k == "وبكره" {
                    if bare(i - 1, in: { $0 == "بعد" }) != nil {
                        dayOffset = 2
                        use((i - 1)..<(i + 1))
                    } else {
                        dayOffset = 1
                        use(i..<(i + 1))
                    }
                } else if k == "غد", bare(i - 1, in: { $0 == "بعد" }) != nil {
                    dayOffset = 2
                    use((i - 1)..<(i + 1))
                } else if k == "اليوم" {
                    if dayOffset == nil { dayOffset = 0 }
                    use(i..<(i + 1))
                } else if k == "الليله" {
                    if dayOffset == nil { dayOffset = 0 }
                    if partOfDay == nil { partOfDay = (21, 0) }
                    use(i..<(i + 1))
                } else if let day = bare(i, in: { SpokenTime.weekdays[$0] != nil }).flatMap({ SpokenTime.weekdays[$0] }) {
                    weekday = day
                    var start = i
                    var end = i + 1
                    if key(i - 1) == "يوم" { start = i - 1 }
                    if let next = key(end), SpokenTime.nextWords.contains(next) { end += 1 }
                    use(start..<end)
                } else if k == "الاسبوع", let next = key(i + 1), SpokenTime.nextWords.contains(next) {
                    nextWeek = true
                    use(i..<(i + 2))
                }
            }
        }

        /// «الصبح», «الضحى», «العصرية», «المساء», «الليل» as a time, when no clock time was said.
        mutating func readPartsOfDay() {
            for i in 0..<count {
                guard let k = key(i), let time = SpokenTime.partsOfDay[k] else { continue }
                if clock == nil, partOfDay == nil { partOfDay = time }
                use(i..<(i + 1))
            }
        }

        // MARK: Result

        func title() -> String {
            var kept: [(word: String, key: String)] = []
            for i in 0..<count where !used[i] { kept.append((words[i], keys[i])) }
            // «ذكرني» and «لا تنسى» lead the sentence, then the task.
            while let first = kept.first, SpokenTime.reminderWords.contains(first.key) { kept.removeFirst() }
            if kept.count >= 2, kept[0].key == "لا", kept[1].key == "تنسي" || kept[1].key == "تنساني" {
                kept.removeFirst(2)
            }
            while let first = kept.first, SpokenTime.connectors.contains(first.key) { kept.removeFirst() }
            while let last = kept.last, SpokenTime.connectors.contains(last.key) { kept.removeLast() }
            return kept.map(\.word).joined(separator: " ")
        }

        func resolve(now: Date, timeZone: TimeZone, schedule: PrayerSchedule?) -> Reading {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let today = calendar.startOfDay(for: now)
            func add(_ days: Int, to date: Date) -> Date { calendar.date(byAdding: .day, value: days, to: date) ?? date }
            func dayString(_ date: Date) -> String {
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }

            var day: Date?
            if let dayOffset { day = add(dayOffset, to: today) }
            if let weekday {
                let current = calendar.component(.weekday, from: today)
                let delta = (weekday - current + 7) % 7
                day = add(delta == 0 ? 7 : delta, to: today)
            } else if nextWeek, dayOffset == nil {
                day = add(7, to: today)
            }

            var cleaned = title()
            if cleaned.isEmpty { cleaned = words.joined(separator: " ") }
            var reading = Reading(title: cleaned)

            if let prayer {
                let offset = prayerOffset ?? 0
                if isFriday, day == nil {
                    let isFridayToday = calendar.component(.weekday, from: today) == 6
                    let passed = schedule?.time(of: .dhuhr, on: now, offsetMinutes: offset).map { $0 <= now } ?? false
                    let delta = (6 - calendar.component(.weekday, from: today) + 7) % 7
                    day = isFridayToday && !passed ? today : add(delta == 0 ? 7 : delta, to: today)
                }
                if day == nil {
                    let passed = schedule?.time(of: prayer, on: now, offsetMinutes: offset).map { $0 <= now } ?? false
                    day = passed ? add(1, to: today) : today
                }
                reading.duePrayer = prayer
                reading.duePrayerOffset = offset
                reading.dueDate = day.map(dayString)
                return reading
            }

            if let fromNow {
                let at = now.addingTimeInterval(TimeInterval(fromNow * 60))
                let parts = calendar.dateComponents([.hour, .minute], from: at)
                reading.dueDate = dayString(at)
                reading.dueTime = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
                return reading
            }

            if let time = clock ?? partOfDay {
                if day == nil {
                    let todayAt = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: today) ?? now
                    day = todayAt > now ? today : add(1, to: today)
                }
                reading.dueTime = String(format: "%02d:%02d", time.hour, time.minute)
            }
            reading.dueDate = day.map(dayString)
            return reading
        }
    }
}
