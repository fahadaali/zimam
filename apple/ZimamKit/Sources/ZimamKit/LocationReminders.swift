import Foundation

/// One place to watch for a location reminder. On iPhone and iPad the app turns it into a
/// `UNLocationNotificationTrigger` over a `CLCircularRegion` with the same identifier; the
/// system watches the region and shows the notification without waking the app.
public struct PlannedRegion: Equatable, Sendable {
    /// The notification request's id and the region's identifier: "location-<reminder id>".
    /// Stable across runs, so rescheduling replaces rather than duplicates.
    public let id: String
    public let reminderId: UUID
    public let taskId: UUID
    public let latitude: Double
    public let longitude: Double
    /// Meters, within what the server accepts.
    public let radius: Double
    /// True notifies on entry («عند الوصول»), false on exit («عند المغادرة»).
    public let onArrive: Bool
    /// «وصلت إلى المكتب: شراء الحليب».
    public let body: String

    public init(id: String, reminderId: UUID, taskId: UUID, latitude: Double, longitude: Double, radius: Double,
                onArrive: Bool, body: String) {
        self.id = id
        self.reminderId = reminderId
        self.taskId = taskId
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.onArrive = onArrive
        self.body = body
    }
}

/// Chooses the location reminders the device watches without «دائماً», and their text.
///
/// With location only while using the app, the system watches each place itself
/// (`UNLocationNotificationTrigger`) and the app is never woken, so a place and a time on the
/// same reminder cannot take each other back: both may arrive. With «دائماً» the app watches
/// places itself instead (`PlaceWatchPlanner`).
///
/// iOS keeps at most 64 pending notifications per app (Zimam uses 60, `ReminderPlanner.defaultLimit`)
/// and watches at most 20 regions per app, location notification triggers included. Location
/// reminders get up to `maxRegions` of the 60; the time window gets the rest
/// (`timeLimit(reserving:)`), so a long list of places never pushes out tomorrow's reminders.
/// Location reminders are never pushed by the server: only the device knows where it is.
public enum LocationReminderPlanner {
    /// Half of iOS's 20 monitored regions, and a sixth of the notification budget.
    public static let maxRegions = 10
    /// The radius choices in the app: 100 m to 1 km. Smaller circles fire late or not at all,
    /// since the system watches regions with cell and Wi-Fi positioning.
    public static let radiusRange: ClosedRange<Double> = 100...1_000
    public static let radiusStep: Double = 50
    public static let defaultRadius: Double = 200
    /// What the server accepts (`Location` in api/src/data/schemas.ts).
    public static let serverRadiusRange: ClosedRange<Double> = 50...10_000

    public struct Point: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public static func regionId(for reminderId: UUID) -> String {
        "location-\(reminderId.uuidString)"
    }

    /// The time reminders' share of the budget once `regions` places are watched.
    public static func timeLimit(reserving regions: Int, total: Int = ReminderPlanner.defaultLimit) -> Int {
        max(0, total - min(max(0, regions), maxRegions))
    }

    /// The places to watch: location reminders of open tasks, at most `limit`. When there are
    /// more, tasks due soonest come first (overdue and today before later, dated before undated),
    /// then the places nearest `near` (the last known position, if any), then a stable order.
    public static func plan(
        tasks: [PlannerTask],
        reminders: [PlannerReminder],
        near: Point? = nil,
        now: Date = Date(),
        limit: Int = maxRegions
    ) -> [PlannedRegion] {
        var openTasks: [UUID: PlannerTask] = [:]
        for task in tasks where !task.isDone { openTasks[task.id] = task }

        struct Candidate {
            let region: PlannedRegion
            let dueKey: String
            let distance: Double
        }

        var candidates: [Candidate] = []
        var seen = Set<UUID>()
        for reminder in reminders where reminder.kind == .location {
            guard let task = openTasks[reminder.taskId], let place = reminder.location,
                  isValid(latitude: place.latitude, longitude: place.longitude),
                  reminder.firing(now: now).watchesPlace,
                  seen.insert(reminder.id).inserted else { continue }
            let region = PlannedRegion(
                id: regionId(for: reminder.id),
                reminderId: reminder.id,
                taskId: task.id,
                latitude: place.latitude,
                longitude: place.longitude,
                radius: clampedRadius(place.radius),
                onArrive: place.trigger == .arrive,
                body: body(placeName: place.name, trigger: place.trigger, taskTitle: task.title)
            )
            let distance = near.map {
                distanceMeters(from: $0, to: Point(latitude: place.latitude, longitude: place.longitude))
            } ?? 0
            // "YYYY-MM-DD" sorts by date as text; undated tasks go last.
            candidates.append(Candidate(region: region, dueKey: task.dueDay ?? "~", distance: distance))
        }

        candidates.sort { a, b in
            if a.dueKey != b.dueKey { return a.dueKey < b.dueKey }
            if a.distance != b.distance { return a.distance < b.distance }
            return a.region.id < b.region.id
        }
        return candidates.prefix(max(0, limit)).map(\.region)
    }

    /// «وصلت إلى المكتب: شراء الحليب» or «غادرت المكتب: شراء الحليب».
    public static func body(placeName: String?, trigger: ReminderRecord.Location.Trigger, taskTitle: String) -> String {
        let place = displayName(placeName)
        switch trigger {
        case .arrive: return "وصلت إلى \(place): \(taskTitle)"
        case .leave: return "غادرت \(place): \(taskTitle)"
        }
    }

    /// The saved name, or «المكان المحدد» when there is none.
    public static func displayName(_ placeName: String?) -> String {
        let trimmed = placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "المكان المحدد" : trimmed
    }

    /// «عند الوصول» or «عند المغادرة».
    public static func triggerText(_ trigger: ReminderRecord.Location.Trigger) -> String {
        switch trigger {
        case .arrive: return "عند الوصول"
        case .leave: return "عند المغادرة"
        }
    }

    /// «١٠٠ م», «٥٥٠ م», «١ كم», «١٫٥ كم», in the locale's digits.
    public static func radiusText(_ meters: Double, locale: Locale) -> String {
        let meters = meters.isFinite ? max(0, meters) : defaultRadius
        if meters >= 1_000 {
            let kilometers = (meters / 100).rounded() / 10
            let number = kilometers.formatted(.number.locale(locale).precision(.fractionLength(0...1)).grouping(.never))
            return "\(number) كم"
        }
        let number = Int(meters.rounded()).formatted(.number.locale(locale).grouping(.never))
        return "\(number) م"
    }

    /// The body when the time beats the place: «حان وقتها قبل وصولك إلى البيت».
    public static func timeCameFirstBody(_ place: ReminderRecord.Location) -> String {
        let name = displayName(place.name)
        switch place.trigger {
        case .arrive: return "حان وقتها قبل وصولك إلى \(name)"
        case .leave: return "حان وقتها قبل مغادرتك \(name)"
        }
    }

    /// «عند الوصول إلى البيت» or «عند مغادرة البيت».
    public static func placeText(_ place: ReminderRecord.Location) -> String {
        let name = displayName(place.name)
        switch place.trigger {
        case .arrive: return "عند الوصول إلى \(name)"
        case .leave: return "عند مغادرة \(name)"
        }
    }

    /// The reminder's line in task details: «عند الوصول إلى البيت», or with a time
    /// «عند الوصول إلى البيت أو غداً ٥:٠٠ م، أيهما أسبق», then what happened once it fired.
    public static func reminderText(_ place: ReminderRecord.Location, firing: ReminderFiring, formatter: DualDateFormatter,
                                    now: Date = Date()) -> String {
        let action = placeText(place)
        switch firing {
        case .everyVisit:
            return action
        case .waiting(let date):
            return "\(action) أو \(formatter.label(for: date, now: now)) \(formatter.time(date))، أيهما أسبق"
        case .firedAtPlace(let date):
            let verb = place.trigger == .arrive ? "وصلت" : "غادرت"
            return "\(action): \(verb) \(formatter.label(for: date, now: now)) \(formatter.time(date))"
        case .firedAtTime(let date):
            return "\(action): حان الوقت أولاً \(formatter.label(for: date, now: now)) \(formatter.time(date))"
        }
    }

    /// «عند الوصول، ٢٠٠ م», for the reminder's row.
    public static func summary(_ place: ReminderRecord.Location, locale: Locale) -> String {
        "\(triggerText(place.trigger))، \(radiusText(place.radius, locale: locale))"
    }

    /// The radius the slider starts on for a saved value: rounded to the step and kept in range.
    public static func sliderRadius(_ meters: Double) -> Double {
        let stepped = (meters / radiusStep).rounded() * radiusStep
        return min(max(stepped, radiusRange.lowerBound), radiusRange.upperBound)
    }

    static func clampedRadius(_ meters: Double) -> Double {
        guard meters.isFinite else { return defaultRadius }
        return min(max(meters, serverRadiusRange.lowerBound), serverRadiusRange.upperBound)
    }

    static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(latitude == 0 && longitude == 0)
    }

    /// Great-circle distance in meters (haversine), enough to rank places.
    public static func distanceMeters(from a: Point, to b: Point) -> Double {
        let earthRadius = 6_371_008.8
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}

// MARK: Whichever comes first

/// Where a location reminder stands. A place alone reminds on every visit until the task is done;
/// a place with a time reminds once, at whichever comes first.
public enum ReminderFiring: Equatable, Sendable {
    /// A place alone: every arrival (or exit) until the task is done.
    case everyVisit
    /// A place and a time, neither reached yet: the place is watched and the time scheduled.
    case waiting(until: Date)
    /// The place came first; the time is taken back.
    case firedAtPlace(Date)
    /// The time came first; the place is no longer watched.
    case firedAtTime(Date)

    /// `firedAt` is set by the device that reached the place first; the time needs no mark,
    /// since every device can tell it has passed.
    public init(at: Date?, firedAt: Milliseconds?, now: Date) {
        if let at {
            if let firedAt {
                self = .firedAtPlace(Date(timeIntervalSince1970: TimeInterval(firedAt) / 1000))
            } else if at <= now {
                self = .firedAtTime(at)
            } else {
                self = .waiting(until: at)
            }
        } else {
            self = .everyVisit
        }
    }

    /// Whether arriving (or leaving) can still remind.
    public var watchesPlace: Bool {
        switch self {
        case .everyVisit, .waiting: true
        case .firedAtPlace, .firedAtTime: false
        }
    }
}

/// Crossing a watched place's edge.
public enum PlaceEvent: Equatable, Sendable {
    case entered, exited
}

/// Whether a location reminder should notify when the device crosses its place's edge.
public enum LocationDecision: Equatable, Sendable {
    case notify
    case skip(Reason)

    public enum Reason: Equatable, Sendable {
        case taskDone
        /// An exit for an arrival reminder, or the other way round.
        case otherDirection
        /// The time came first, or the place already fired.
        case alreadyFired
        /// The same reminder notified moments ago: GPS jitter at the edge.
        case tooSoon
    }

    /// A reminder that just notified stays quiet this long, so wandering along the edge of a
    /// place does not repeat it. Leaving and coming back later reminds again.
    public static let quietPeriod: TimeInterval = 30 * 60

    public static func decide(event: PlaceEvent, trigger: ReminderRecord.Location.Trigger, taskIsDone: Bool,
                              firing: ReminderFiring, lastNotified: Date?, now: Date) -> LocationDecision {
        if taskIsDone { return .skip(.taskDone) }
        let wanted: PlaceEvent = trigger == .arrive ? .entered : .exited
        if event != wanted { return .skip(.otherDirection) }
        if !firing.watchesPlace { return .skip(.alreadyFired) }
        if let lastNotified, now.timeIntervalSince(lastNotified) < quietPeriod { return .skip(.tooSoon) }
        return .notify
    }
}

/// One place the device watches with «دائماً» (`CLMonitor`), and the reminders it serves.
public struct WatchedPlace: Equatable, Sendable {
    /// The monitor's condition id: "place-<placeId>" for a saved place, so every reminder there
    /// shares one region, or "loc-<reminderId>" for a place that was not saved.
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public let radius: Double
    /// Reminders watched here, in a stable order.
    public let reminderIds: [UUID]

    public init(id: String, latitude: Double, longitude: Double, radius: Double, reminderIds: [UUID]) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.reminderIds = reminderIds
    }
}

/// Chooses the places the device watches when the app may use location «دائماً».
///
/// The app watches places, not reminders: one region for «البيت» serves every reminder there,
/// arriving and leaving. iOS watches at most 20 regions per app; the app itself shows these
/// notifications when woken, so they take nothing from the 60 local notifications.
public enum PlaceWatchPlanner {
    public static let maxPlaces = 20

    public static func conditionId(for place: ReminderRecord.Location, reminderId: UUID) -> String {
        if let placeId = place.placeId { return "place-\(placeId.uuidString)" }
        return "loc-\(reminderId.uuidString)"
    }

    /// Places of open tasks' location reminders that can still remind, at most `limit`. When
    /// there are more, places with the soonest-due task come first (as `LocationReminderPlanner`),
    /// then the nearest to `near`, then a stable order.
    public static func plan(
        tasks: [PlannerTask],
        reminders: [PlannerReminder],
        near: LocationReminderPlanner.Point? = nil,
        now: Date,
        limit: Int = maxPlaces
    ) -> [WatchedPlace] {
        var openTasks: [UUID: PlannerTask] = [:]
        for task in tasks where !task.isDone { openTasks[task.id] = task }

        struct Group {
            var place: ReminderRecord.Location
            var reminderIds: [UUID]
            var dueKey: String
        }
        var groups: [String: Group] = [:]
        var seen = Set<UUID>()
        // A stable order, so the same copy of a place wins each time.
        for reminder in reminders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where reminder.kind == .location {
            guard let task = openTasks[reminder.taskId], let place = reminder.location,
                  LocationReminderPlanner.isValid(latitude: place.latitude, longitude: place.longitude),
                  reminder.firing(now: now).watchesPlace,
                  seen.insert(reminder.id).inserted else { continue }
            let id = conditionId(for: place, reminderId: reminder.id)
            let dueKey = task.dueDay ?? "~"
            if var group = groups[id] {
                group.reminderIds.append(reminder.id)
                group.dueKey = min(group.dueKey, dueKey)
                groups[id] = group
            } else {
                groups[id] = Group(place: place, reminderIds: [reminder.id], dueKey: dueKey)
            }
        }

        struct Candidate {
            let place: WatchedPlace
            let dueKey: String
            let distance: Double
        }
        let candidates = groups.map { id, group in
            let point = LocationReminderPlanner.Point(latitude: group.place.latitude, longitude: group.place.longitude)
            return Candidate(
                place: WatchedPlace(id: id, latitude: group.place.latitude, longitude: group.place.longitude,
                                    radius: LocationReminderPlanner.clampedRadius(group.place.radius),
                                    reminderIds: group.reminderIds),
                dueKey: group.dueKey,
                distance: near.map { LocationReminderPlanner.distanceMeters(from: $0, to: point) } ?? 0
            )
        }
        .sorted { a, b in
            if a.dueKey != b.dueKey { return a.dueKey < b.dueKey }
            if a.distance != b.distance { return a.distance < b.distance }
            return a.place.id < b.place.id
        }
        return candidates.prefix(max(0, limit)).map(\.place)
    }
}
