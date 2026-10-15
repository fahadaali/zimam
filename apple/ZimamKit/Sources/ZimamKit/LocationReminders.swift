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

/// Chooses the location reminders the device watches, and their text.
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
