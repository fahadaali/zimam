import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A task said or dictated as one sentence («ذكرني أراجع العقد بعد العصر بكرة»): from the add
/// screen's «إملاء», from Siri, and from the watch. The assistant reads it when it can; when it
/// cannot (no connection, signed out, no plan, the month's quota used, the provider down, or it
/// takes too long) the device reads its time itself (`SpokenTime`) and the rest becomes the title,
/// so a spoken task is never lost.
public struct SpokenTask: Equatable, Sendable {
    /// The assistant's reading, or only the sentence as the title.
    public var suggestion: TaskSuggestion
    /// Why the assistant did not read the sentence; nil when it did.
    public var problem: AssistantProblem?

    /// The assistant's reading.
    public init(suggestion: TaskSuggestion) {
        self.suggestion = suggestion
        problem = nil
    }

    /// The sentence as it was said, as the title.
    public init(text: String, problem: AssistantProblem) {
        suggestion = TaskSuggestion(title: text.trimmingCharacters(in: .whitespacesAndNewlines))
        self.problem = problem
    }

    /// The sentence read on the device (`SpokenTime`) when the assistant could not: its time,
    /// prayer and day, and the rest as the title. `problem` still says why the assistant did not.
    public static func local(_ text: String, problem: AssistantProblem, now: Date = Date(), timeZone: TimeZone = .current,
                             schedule: PrayerSchedule? = nil) -> SpokenTask {
        let reading = SpokenTime.read(text, now: now, timeZone: timeZone, schedule: schedule)
        var spoken = SpokenTask(text: text, problem: problem)
        spoken.suggestion = TaskSuggestion(title: reading.title, dueDate: reading.dueDate, dueTime: reading.dueTime,
                                           duePrayer: reading.duePrayer, duePrayerOffset: reading.duePrayerOffset)
        return spoken
    }

    /// Read on the device instead: the assistant could not, and a day, time or prayer was found.
    public var readLocally: Bool {
        problem != nil && (suggestion.dueDate != nil || suggestion.dueTime != nil || suggestion.duePrayer != nil)
    }

    /// The task to add, shaped as the app's `Store.addTask` and the server shape it: a time
    /// only for a dated task that is not tied to a prayer, an offset only with a prayer, and a
    /// prayer without a day means today. `defaultDueDate` is the day when the sentence names
    /// none (the watch adds to today); `today` is "2026-10-15" in the user's time zone.
    public func record(today: String, defaultDueDate: String? = nil) -> TaskRecord {
        let reading = suggestion
        var day = reading.dueDate ?? defaultDueDate
        if day == nil && reading.duePrayer != nil { day = today }
        let notes = reading.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskRecord(
            projectId: reading.projectId,
            title: reading.title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes?.isEmpty == false ? notes : nil,
            priority: reading.priority,
            tags: reading.tags,
            dueDate: day,
            dueTime: day != nil && reading.duePrayer == nil ? reading.dueTime : nil,
            duePrayer: reading.duePrayer,
            duePrayerOffset: reading.duePrayer == nil ? nil : (reading.duePrayerOffset ?? 0)
        )
    }

    /// The time that competes with the sentence's place («إذا وصلت البيت أو الساعة ٥»): the
    /// task's day and clock time, as the reminder's `at`. Nil without a place, or without a clock
    /// time (a place with a prayer reminds at the place alone).
    public func placeReminderAt(today: String, timeZone: TimeZone) -> String? {
        guard suggestion.place != nil else { return nil }
        let task = record(today: today)
        guard let day = task.dueDate, let time = task.dueTime else { return nil }
        let parts = (day + "-" + time.replacingOccurrences(of: ":", with: "-")).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 5 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4])
        guard let date = calendar.date(from: components) else { return nil }
        return ReminderPlanner.isoString(from: date, timeZone: timeZone)
    }
}

public extension APIClient {
    /// Reads a spoken sentence with the assistant (`POST /v1/assistant/parse`), falling back to
    /// reading it on the device (`SpokenTask.local`) on any failure or after `timeout` (Siri does
    /// not wait long). Never throws. Nothing is saved: the caller adds the task. `schedule` (the
    /// user's place) lets the device's reading move a prayer that has passed to tomorrow.
    func readSpokenTask(_ text: String, now: Date = Date(), timeZone: TimeZone = .current,
                        schedule: PrayerSchedule? = nil, timeout: Duration = .seconds(8)) async -> SpokenTask {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return SpokenTask(text: sentence, problem: .invalidInput) }
        let first: SpokenTask? = await withTaskGroup(of: SpokenTask?.self) { group in
            group.addTask {
                do {
                    let suggestion = try await self.suggestTask(from: sentence, now: now, timeZone: timeZone)
                    // A reading without a title keeps the words as they were said.
                    if suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return SpokenTask.local(sentence, problem: .unavailable, now: now, timeZone: timeZone, schedule: schedule)
                    }
                    return SpokenTask(suggestion: suggestion)
                } catch {
                    return SpokenTask.local(sentence, problem: AssistantProblem(error), now: now, timeZone: timeZone,
                                            schedule: schedule)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
        return first ?? SpokenTask.local(sentence, problem: .unavailable, now: now, timeZone: timeZone, schedule: schedule)
    }
}
