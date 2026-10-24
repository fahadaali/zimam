import Foundation
import Observation
import ZimamKit

/// Today's open tasks on the watch. The watch has no local store: it asks the API for
/// today's tasks and sends completions and new tasks right away, with the session the
/// iPhone app handed over (see `PhoneLink`).
@MainActor
@Observable
final class WatchModel {
    /// The one model: the app's scene and its background refresh (`WatchRefresh`) share it.
    static let shared = WatchModel()

    private(set) var tasks: [TaskRecord] = []
    /// Tasks just tapped: their circle fills, and after a second (`duration-linger`) the
    /// completion is sent and they leave the list. A second tap within that second undoes it.
    private(set) var finishing: Set<UUID> = []
    private(set) var isSignedIn: Bool
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// One line after adding a task that is not due today: «أُضيفت «مراجعة العقد»، غداً.», and
    /// when the sentence named a place, that its reminder was not added here.
    private(set) var notice: String?
    private(set) var calendar: CalendarKind
    /// Top-level tasks due today and done, for the complications' ring (WatchGlance).
    @ObservationIgnored private var doneToday = 0
    /// Tasks added here that the server does not have yet. A refresh while the assistant reads
    /// the sentence or the push is in flight keeps them in the list instead of dropping them.
    @ObservationIgnored private var unsent: [UUID: TaskRecord] = [:]
    /// Counts refreshes, so one that answers late does not overwrite a newer list.
    @ObservationIgnored private var refreshes = 0
    /// Today's list came from the server since launch: before that, a snapshot made from the
    /// empty list would show the day as done.
    @ObservationIgnored private var loaded = false
    /// The second a tapped task waits before its completion is sent, by task.
    @ObservationIgnored private var lingers: [UUID: Task<Void, Never>] = [:]
    /// Completions on their way to the server: too late to undo.
    @ObservationIgnored private var sending: Set<UUID> = []

    @ObservationIgnored let api: APIClient
    @ObservationIgnored private let link = PhoneLink()

    nonisolated static let tokenAccount = "token"
    private static let calendarKey = "calendar"

    init() {
        let signedIn: Bool
        do {
            signedIn = try Keychain.value(Self.tokenAccount) != nil
        } catch {
            // The Keychain cannot answer for now: requests wait for the token (`APIClient`).
            signedIn = true
        }
        isSignedIn = signedIn
        calendar = UserDefaults.standard.string(forKey: Self.calendarKey).flatMap(CalendarKind.init(rawValue:)) ?? .hijri
        let configured = Bundle.main.object(forInfoDictionaryKey: "ZimamAPIURL") as? String
        let baseURL = configured.flatMap(URL.init(string:)) ?? URL(string: "https://api.zimam.work")!
        api = APIClient(baseURL: baseURL) { try Keychain.value(WatchModel.tokenAccount) }
        link.onSession = { [weak self] token, calendar in
            self?.received(token: token, calendar: calendar)
        }
        link.start()
    }

    /// Dates the Zimam way, with the user's primary calendar first.
    var formatter: DualDateFormatter {
        DualDateFormatter(primary: calendar, locale: ZimamLocale.current)
    }

    func refresh() async {
        guard isSignedIn else {
            link.requestSession()
            return
        }
        refreshes += 1
        let current = refreshes
        isLoading = true
        // Only the newest refresh clears it, so an older one answering first does not show an
        // empty list as «لا مهام اليوم» while the newer one is still loading.
        defer { if current == refreshes { isLoading = false } }
        do {
            let today = Self.today()
            let api = self.api
            // Today's done count (the complications' ring) is asked for at the same time.
            async let finished = try? api.listTasks(status: "done", dueFrom: today, dueTo: today, limit: 200)
            let open = try await api.listTasks(status: "open", dueTo: today, limit: 200)
            guard current == refreshes else { return }
            let listed = open.filter { $0.parentId == nil }
            let known = Set(listed.map(\.id))
            let added = unsent.values
                .filter { !known.contains($0.id) && ($0.dueDate ?? today) <= today }
                .sorted { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
            tasks = listed + added
            loaded = true
            errorMessage = nil
            if let done = await finished, current == refreshes {
                doneToday = done.filter { $0.parentId == nil }.count
            }
            publishGlance()
        } catch let error as APIError where error.isUnauthorized {
            signOut()
        } catch {
            errorMessage = "تعذّر الاتصال بزمام. حاول مرة أخرى."
        }
    }

    /// A tap on a task's row: the circle fills, and after `duration-linger` the completion is sent.
    /// A second tap within that second undoes it, nothing having been sent (design/README.md).
    func toggle(_ task: TaskRecord) {
        guard !sending.contains(task.id) else { return }
        if finishing.contains(task.id) {
            lingers.removeValue(forKey: task.id)?.cancel()
            finishing.remove(task.id)
            return
        }
        finishing.insert(task.id)
        // The wrist often drops right after the tap, and watchOS then suspends the app within
        // seconds: this asks it for the time to send the completion, linger included.
        let activity = Self.keepRunning("Completing a task")
        lingers[task.id] = Task {
            defer { activity.signal() }
            // A recurring task's next occurrence is read while the second passes, so it goes
            // with the completion in one request.
            let followUp = Task { try await nextOccurrence(after: task) }
            do { try await Task.sleep(for: .seconds(ZimamMotion.linger)) } catch {
                followUp.cancel()
                return
            }
            // A second tap just as the sleep ended may come before this resumes: cancelling then
            // is too late to stop the sleep, so this checks again.
            guard !Task.isCancelled, finishing.contains(task.id) else {
                followUp.cancel()
                return
            }
            lingers[task.id] = nil
            await complete(task, followUp: followUp)
        }
    }

    /// Completes a task on the server with a recurring task's next occurrence, as on the phone, in
    /// one request: the series does not end because the app was suspended between two.
    private func complete(_ task: TaskRecord, followUp: Task<Occurrence?, Error>) async {
        sending.insert(task.id)
        defer { sending.remove(task.id) }
        var done = task
        done.status = .done
        done.completedAt = Milliseconds.now
        done.updatedAt = max(Milliseconds.now, task.updatedAt + 1)
        do {
            let next = try await followUp.value
            var mutations: [Mutation] = [.upsert(.task(done))]
            if let next {
                mutations.append(.upsert(.task(next.task)))
                mutations += next.reminders.map { .upsert(.reminder($0)) }
            }
            let results = try await api.push(mutations)
            errorMessage = nil
            let nextAdded = next != nil && results.dropFirst().first?.status == .applied
            if results.first?.status == .applied {
                tasks.removeAll { $0.id == task.id }
                finishing.remove(task.id)
                if task.dueDate == Self.today() { doneToday += 1 }
                publishGlance()
                if next != nil, !nextAdded { errorMessage = "أُنجزت المهمة، وتعذّرت إضافة موعدها التالي." }
            } else {
                // Changed or deleted elsewhere: the next occurrence sent with it goes too (the
                // server deletes its reminders with it), and the list shows what the server has now.
                finishing.remove(task.id)
                if let next, nextAdded {
                    let at = max(Milliseconds.now, next.task.updatedAt)
                    _ = try? await api.push([.delete(.task, id: next.task.id, updatedAt: at)])
                }
                await refresh()
            }
        } catch let error as APIError where error.isUnauthorized {
            finishing.remove(task.id)
            signOut()
        } catch {
            finishing.remove(task.id)
            errorMessage = "تعذّر إنجاز المهمة. حاول مرة أخرى."
        }
    }

    /// A recurring task's next occurrence and its reminders.
    nonisolated struct Occurrence: Sendable {
        let task: TaskRecord
        let reminders: [ReminderRecord]
    }

    /// The next occurrence the phone's `Store` adds (`NextOccurrence`), with the task's reminders
    /// moved to its day; nil when the task does not repeat, the series ends, or another device
    /// already added it. Throws when the server cannot be read, so the completion waits too.
    private func nextOccurrence(after task: TaskRecord) async throws -> Occurrence? {
        let days = DualDateFormatter()
        let today = days.dayString(from: Date())
        guard let next = NextOccurrence.task(after: task, today: today, timeZone: days.timeZone),
              let day = next.dueDate else { return nil }
        let api = self.api
        async let reminders = api.taskReminders(task.id)
        let open = try await api.listTasks(status: "open", dueFrom: day, dueTo: day, limit: 200)
        if open.contains(where: { NextOccurrence.isSame($0, as: task, on: day) }) { return nil }
        let copies = NextOccurrence.reminders(try await reminders, movedTo: next.id, from: task.dueDate ?? today, to: day,
                                              timeZone: days.timeZone)
        return Occurrence(task: next, reminders: copies)
    }

    /// Asks watchOS to keep the app running until the semaphore is signalled, for as long as it
    /// allows (`performExpiringActivity`, whose block waits on its own queue).
    private nonisolated static func keepRunning(_ reason: String) -> DispatchSemaphore {
        let finished = DispatchSemaphore(value: 0)
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { @Sendable expired in
            // Called again with `expired` when the time is up: that releases the first call.
            if expired {
                finished.signal()
                return
            }
            finished.wait()
        }
        return finished
    }

    /// Adds a task from what was typed or dictated. Online, the assistant reads the sentence
    /// («ذكرني أراجع العقد بعد العصر بكرة»: title, day, time or prayer) as on the iPhone;
    /// otherwise, or when it cannot help, the words become the title of a task due today.
    func add(title: String) async {
        let trimmed = ServerText.clip(title.trimmingCharacters(in: .whitespacesAndNewlines), to: ServerText.maxTitle)
        guard !trimmed.isEmpty else { return }
        let today = Self.today()
        // Shown at once as said; the assistant's reading replaces it when it comes.
        let placeholder = TaskRecord(title: trimmed, dueDate: today)
        tasks.append(placeholder)
        unsent[placeholder.id] = placeholder
        notice = nil
        // The place the iPhone sent lets the device's own reading move a passed prayer to tomorrow.
        let reading = await api.readSpokenTask(trimmed, timeZone: formatter.timeZone, schedule: WatchPrayerStore.read()?.schedule)
        if reading.problem == .signedOut {
            signOut()
            return
        }
        var record = reading.record(today: today, defaultDueDate: today)
        record.id = placeholder.id
        let index = tasks.firstIndex(where: { $0.id == placeholder.id })
        if let day = record.dueDate, day > today {
            // Not today's: it leaves the list, and a line says when it is due.
            if let index { tasks.remove(at: index) }
            unsent[record.id] = nil
            if let date = formatter.date(fromDay: day) {
                notice = "أُضيفت «\(record.title)»، \(formatter.label(for: date))."
            }
        } else {
            // In the placeholder's place; back in the list if a refresh replaced it meanwhile.
            if let index { tasks[index] = record } else { tasks.append(record) }
            unsent[record.id] = record
        }
        var mutations: [Mutation] = [.upsert(.task(record))]
        if record.dueTime != nil || record.duePrayer != nil {
            // «عند الموعد», as the phone's add paths (`Store.ensureAtTimeReminder`) and the
            // server's assistant add it: a task's time does not remind by itself.
            mutations.append(.upsert(.reminder(ReminderRecord(taskId: record.id, kind: .relative, offsetMinutes: 0))))
        }
        do {
            _ = try await api.push(mutations)
            unsent[record.id] = nil
            errorMessage = nil
            if let place = reading.suggestion.place {
                // The watch keeps no places, so it cannot add a place reminder.
                let line = "لم يُضف تذكير المكان «\(place.name)» من الساعة، فأضفه من الآيفون."
                notice = notice.map { $0 + " " + line } ?? line
            }
            publishGlance()
        } catch let error as APIError where error.isUnauthorized {
            signOut()
        } catch {
            unsent[record.id] = nil
            tasks.removeAll { $0.id == record.id }
            errorMessage = "تعذّرت إضافة المهمة. حاول مرة أخرى."
        }
    }

    // MARK: Session

    /// What the iPhone sent: the token (empty after sign-out there; nil when only the calendar or
    /// the place came, see `PhoneLink`) and the primary calendar.
    private func received(token: String?, calendar calendarName: String?) {
        if let calendarName, let kind = CalendarKind(rawValue: calendarName) {
            calendar = kind
            UserDefaults.standard.set(calendarName, forKey: Self.calendarKey)
        }
        // The place may have changed with it: the snapshot's prayer times follow it.
        guard let token else {
            if loaded { publishGlance() }
            return
        }
        let current = Keychain.read(Self.tokenAccount)
        if token.isEmpty {
            if current != nil { signOut() }
            return
        }
        guard token != current, Keychain.write(token, for: Self.tokenAccount) else {
            if loaded { publishGlance() }
            return
        }
        // Another account's token (the phone signed in to another): its list and taps go.
        if current != nil { clearList() }
        isSignedIn = true
        Task { await refresh() }
    }

    private func signOut() {
        Keychain.delete(Self.tokenAccount)
        isSignedIn = false
        clearList()
        publishGlance()
    }

    /// Forgets the account's tasks, and the taps still waiting their second.
    private func clearList() {
        tasks = []
        loaded = false
        lingers.values.forEach { $0.cancel() }
        lingers = [:]
        sending = []
        finishing = []
        unsent = [:]
        doneToday = 0
    }

    /// Hands today's tasks to the complications (WatchGlance.swift).
    private func publishGlance() {
        WatchGlance.publish(tasks: tasks, doneCount: doneToday, isSignedIn: isSignedIn, calendar: calendar)
    }

    // MARK: Helpers

    private static func today() -> String {
        DualDateFormatter().dayString(from: Date())
    }
}
