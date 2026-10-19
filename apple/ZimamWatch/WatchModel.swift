import Foundation
import Observation
import ZimamKit

/// Today's open tasks on the watch. The watch has no local store: it asks the API for
/// today's tasks and sends completions and new tasks right away, with the session the
/// iPhone app handed over (see `PhoneLink`).
@MainActor
@Observable
final class WatchModel {
    private(set) var tasks: [TaskRecord] = []
    /// Tasks just completed: their circle fills, then they leave the list after a second.
    private(set) var finishing: Set<UUID> = []
    private(set) var isSignedIn: Bool
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// One line after adding a task that is not due today: «أُضيفت «مراجعة العقد»، غداً.»
    private(set) var notice: String?
    private(set) var calendar: CalendarKind
    /// Top-level tasks due today and done, for the complications' ring (WatchGlance).
    @ObservationIgnored private var doneToday = 0
    /// Tasks added here that the server does not have yet. A refresh while the assistant reads
    /// the sentence or the push is in flight keeps them in the list instead of dropping them.
    @ObservationIgnored private var unsent: [UUID: TaskRecord] = [:]
    /// Counts refreshes, so one that answers late does not overwrite a newer list.
    @ObservationIgnored private var refreshes = 0

    @ObservationIgnored let api: APIClient
    @ObservationIgnored private let link = PhoneLink()

    nonisolated static let tokenAccount = "token"
    private static let calendarKey = "calendar"

    init() {
        isSignedIn = Keychain.read(Self.tokenAccount) != nil
        calendar = UserDefaults.standard.string(forKey: Self.calendarKey).flatMap(CalendarKind.init(rawValue:)) ?? .hijri
        let configured = Bundle.main.object(forInfoDictionaryKey: "ZimamAPIURL") as? String
        let baseURL = configured.flatMap(URL.init(string:)) ?? URL(string: "https://zimam.fahad2ao.workers.dev")!
        api = APIClient(baseURL: baseURL) { Keychain.read(WatchModel.tokenAccount) }
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
        isLoading = true
        defer { isLoading = false }
        refreshes += 1
        let current = refreshes
        do {
            let today = Self.today()
            let open = try await api.listTasks(status: "open", dueTo: today, limit: 200)
            guard current == refreshes else { return }
            let listed = open.filter { $0.parentId == nil }
            let known = Set(listed.map(\.id))
            let added = unsent.values
                .filter { !known.contains($0.id) && ($0.dueDate ?? today) <= today }
                .sorted { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
            tasks = listed + added
            errorMessage = nil
            if let done = try? await api.listTasks(status: "done", dueFrom: Self.today(), dueTo: Self.today(), limit: 200) {
                doneToday = done.filter { $0.parentId == nil }.count
            }
            publishGlance()
        } catch let error as APIError where error.isUnauthorized {
            signOut()
        } catch {
            errorMessage = "تعذّر الاتصال بزمام. حاول مرة أخرى."
        }
    }

    /// Completes a task on the server. A recurring task gets its next occurrence, as on the phone.
    func complete(_ task: TaskRecord) async {
        guard !finishing.contains(task.id) else { return }
        finishing.insert(task.id)
        var done = task
        done.status = .done
        done.completedAt = Milliseconds.now
        done.updatedAt = max(Milliseconds.now, task.updatedAt + 1)
        var mutations: [Mutation] = [.upsert(.task(done))]
        if let next = Self.nextOccurrence(of: task) {
            mutations.append(.upsert(.task(next)))
        }
        do {
            let results = try await api.push(mutations)
            errorMessage = nil
            if results.first?.status == .applied {
                try? await Task.sleep(for: .seconds(1))
                tasks.removeAll { $0.id == task.id }
                finishing.remove(task.id)
                if task.dueDate == Self.today() { doneToday += 1 }
                publishGlance()
            } else {
                // Changed or deleted elsewhere: show what the server has now.
                finishing.remove(task.id)
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

    /// Adds a task from what was typed or dictated. Online, the assistant reads the sentence
    /// («ذكرني أراجع العقد بعد العصر بكرة»: title, day, time or prayer) as on the iPhone;
    /// otherwise, or when it cannot help, the words become the title of a task due today.
    func add(title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let today = Self.today()
        // Shown at once as said; the assistant's reading replaces it when it comes.
        let placeholder = TaskRecord(title: trimmed, dueDate: today)
        tasks.append(placeholder)
        unsent[placeholder.id] = placeholder
        notice = nil
        let reading = await api.readSpokenTask(trimmed, timeZone: formatter.timeZone)
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
        do {
            _ = try await api.push([.upsert(.task(record))])
            unsent[record.id] = nil
            errorMessage = nil
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

    private func received(token: String, calendar calendarName: String?) {
        if let calendarName, let kind = CalendarKind(rawValue: calendarName) {
            calendar = kind
            UserDefaults.standard.set(calendarName, forKey: Self.calendarKey)
        }
        let current = Keychain.read(Self.tokenAccount)
        if token.isEmpty {
            if current != nil { signOut() }
            return
        }
        guard token != current else { return }
        Keychain.write(token, for: Self.tokenAccount)
        isSignedIn = true
        Task { await refresh() }
    }

    private func signOut() {
        Keychain.delete(Self.tokenAccount)
        isSignedIn = false
        tasks = []
        finishing = []
        unsent = [:]
        doneToday = 0
        publishGlance()
    }

    /// Hands today's tasks to the complications (WatchGlance.swift).
    private func publishGlance() {
        WatchGlance.publish(tasks: tasks, doneCount: doneToday, isSignedIn: isSignedIn, calendar: calendar)
    }

    // MARK: Helpers

    private static func today() -> String {
        DualDateFormatter().dayString(from: Date())
    }

    /// The same next occurrence the phone's `Store` adds. Reminders are not copied from the watch.
    private static func nextOccurrence(of task: TaskRecord) -> TaskRecord? {
        guard let text = task.recurrence, let rule = Recurrence(rrule: text) else { return nil }
        let days = DualDateFormatter()
        let today = days.dayString(from: Date())
        let base = task.dueDate ?? today
        guard let next = rule.nextOccurrence(after: base, notBefore: today, timeZone: days.timeZone) else { return nil }
        var record = task
        record.id = UUID()
        record.status = .todo
        record.completedAt = nil
        record.dueDate = next.day
        record.recurrence = next.rule.rrule
        record.createdAt = nil
        record.updatedAt = Milliseconds.now
        return record
    }
}
