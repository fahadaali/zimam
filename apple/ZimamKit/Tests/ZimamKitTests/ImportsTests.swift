import Foundation
import Testing
@testable import ZimamKit

struct ImportsTests {
    /// A URL from a literal the test knows is valid; fails the test, not the run, if it is not.
    private func makeURL(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    let ar = Locale(identifier: "ar-SA")

    @Test func decodesSourcesInTheServerShape() throws {
        let json = """
        {"maxFileBytes":5242880,"sources":[
          {"id":"todoist-csv","label":"Todoist","input":"file","extensions":[".csv"]},
          {"id":"todoist-api","label":"Todoist","input":"token"},
          {"id":"csv","label":"CSV","input":"file","extensions":[".CSV",".tsv",".txt"]},
          {"id":"trello","label":"Trello","input":"oauth","available":false},
          {"id":"pigeon","label":"Pigeon","input":"carrier","available":true}
        ]}
        """
        let sources = try JSONDecoder().decode(ImportSources.self, from: Data(json.utf8))
        #expect(sources.maxFileBytes == 5_242_880)
        #expect(sources.sources.map(\.id) == ["todoist-csv", "todoist-api", "csv", "trello", "pigeon"])
        #expect(sources.sources[0].input == .file)
        #expect(sources.sources[1].input == .token)
        #expect(sources.sources[1].extensions == [])
        #expect(sources.sources[2].extensions == [".csv", ".tsv", ".txt"])
        // Without `available` (older servers), a source can start.
        #expect(sources.sources[0].available)
        #expect(sources.sources[3].input == .oauth)
        #expect(!sources.sources[3].available)
        // A kind of source this version cannot start is kept apart, not a decoding error.
        #expect(sources.sources[4].input == .unsupported)
    }

    @Test func readsTheOAuthCallback() throws {
        let id = "Zk3_q-8vXc1Lr0aT9yUeWb2NpHs4MdFg7jK6oQiAxYz"
        #expect(ImportCallback(url: try makeURL("zimam://import-callback?pending=\(id)&source=notion")) == .pending(ImportCallback.Pending(id: id, source: "notion", token: nil)))
        // Trello's token comes in the fragment, never the query.
        let trello = "ATTA0123456789abcdef0123456789abcdef"
        #expect(ImportCallback(url: try makeURL("zimam://import-callback?pending=\(id)&source=trello#token=\(trello)")) == .pending(ImportCallback.Pending(id: id, source: "trello", token: trello)))
        #expect(ImportCallback(url: try makeURL("zimam://import-callback?pending=\(id)&source=Not%20One")) == .pending(ImportCallback.Pending(id: id, source: nil, token: nil)))
        #expect(ImportCallback(url: try makeURL("zimam://import-callback?error=denied")) == .failure("denied"))
        #expect(ImportCallback(url: try makeURL("zimam://import-callback?pending=short")) == nil)
        // A job id in the link starts nothing: only the server's confirm does.
        #expect(ImportCallback(url: try makeURL("zimam://import-callback?job=0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f")) == nil)
        #expect(ImportCallback(url: try makeURL("zimam://join/ABC")) == nil)
        #expect(ImportCallback(url: try makeURL("https://example.com/import-callback?pending=\(id)")) == nil)
        #expect(ImportText.connect(ImportSource(id: "notion", label: "Notion", input: .oauth)) == "الربط بـ Notion")
        #expect(ImportText.oauthMessage("denied").hasPrefix("لم يكتمل الإذن"))
        #expect(ImportText.title(forSource: "ticktick-api", label: "TickTick") == "TickTick: الربط بالحساب")
    }

    @Test func asksBeforeImportingIntoTheSignedInAccount() {
        let account = ImportText.accountLabel(name: "فهد", email: "fahad@example.com")
        #expect(account == "فهد، fahad@example.com")
        #expect(ImportText.accountLabel(name: " ", email: nil) == nil)
        #expect(ImportText.confirmQuestion(source: "notion", account: account) == "استيراد بيانات Notion إلى حسابك فهد، fahad@example.com؟")
        #expect(ImportText.confirmQuestion(source: nil, account: nil) == "استيراد البيانات إلى حسابك؟")
        #expect(ImportText.confirmMessage(for: APIError(status: 404, code: "not_found", message: "")).contains("لا يخص حسابك"))
        #expect(ImportText.confirmMessage(for: APIError(status: 410, code: "expired", message: "")).contains("استُعمل من قبل"))
    }

    @Test func decodesAJobWithCountsWarningsAndErrors() throws {
        let json = """
        {"job":{"id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","source":"todoist-csv","status":"running","fileName":"زواج.csv",
          "progress":{"processed":50,"total":121},
          "counts":{"created":48,"updated":0,"unchanged":0,"skipped":0,"failed":2,
                    "byEntity":{"project":{"created":1,"updated":0,"unchanged":0,"skipped":0,"failed":0}}},
          "warnings":["مهام لم يُفهم تكرارها، فحُفظ نصه في ملاحظاتها: ٣"],
          "errors":[{"entity":"task","title":"شراء","message":"تعذّر استيراد المهمة «شراء»."}],
          "error":null,"createdAt":1791882000000,"updatedAt":1791882005000,"finishedAt":null}}
        """
        let job = try APIClient.decodeJob(Data(json.utf8))
        #expect(job.id == "0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f")
        #expect(job.status == .running)
        #expect(!job.isFinished)
        #expect(job.fileName == "زواج.csv")
        #expect(job.progress == ImportJob.Progress(processed: 50, total: 121))
        #expect(job.counts == ImportJob.Counts(created: 48, failed: 2))
        #expect(job.warnings.count == 1)
        #expect(job.errors.first?.entity == "task")
        #expect(job.error == nil)
        #expect(job.finishedAt == nil)
        #expect(ImportText.progress(job, locale: ar) == "٥٠ من ١٢١")
        #expect(abs((ImportText.fraction(job) ?? 0) - (50.0 / 121.0)) <= 0.0001)
    }

    @Test func decodesAFailedJobAndAJobList() throws {
        let json = """
        {"jobs":[
          {"id":"a","source":"todoist-api","status":"failed","fileName":null,"progress":{"processed":0,"total":0},
           "counts":{"created":0,"updated":0,"unchanged":0,"skipped":0,"failed":0,"byEntity":{}},"warnings":[],"errors":[],
           "error":{"code":"token_rejected","message":"رفض Todoist الرمز. انسخه مرة أخرى."},"createdAt":1,"updatedAt":2,"finishedAt":2},
          {"id":"b","source":"csv","status":"exploding","progress":{"processed":0,"total":0},
           "counts":{"created":0,"updated":0,"unchanged":0,"skipped":0,"failed":0},"warnings":[],"errors":[],"error":null,
           "createdAt":1,"updatedAt":1,"finishedAt":null}
        ]}
        """
        struct Response: Decodable { let jobs: [ImportJob] }
        let jobs = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).jobs
        #expect(jobs[0].status == .failed)
        #expect(jobs[0].isFinished)
        #expect(jobs[0].error?.code == "token_rejected")
        #expect(ImportText.summary(jobs[0], locale: ar) == "رفض Todoist الرمز. انسخه مرة أخرى.")
        // An unknown status keeps being followed rather than read as finished.
        #expect(jobs[1].status == .running)
    }

    @Test func progressAndSummaryText() {
        let queued = ImportJob(id: "x", source: "csv", status: .queued)
        #expect(ImportText.progress(queued, locale: ar) == "ينتظر دوره في الطابور…")
        #expect(ImportText.fraction(queued) == nil)
        let reading = ImportJob(id: "x", source: "csv", status: .running)
        #expect(ImportText.progress(reading, locale: ar) == "تُقرأ البيانات…")

        let done = ImportJob(id: "x", source: "csv", status: .done, progress: .init(processed: 50, total: 50),
                             counts: .init(created: 48, updated: 2))
        #expect(ImportText.summary(done, locale: ar) == "أُضيف ٤٨ عنصراً، وحُدِّث عنصران.")
        #expect(ImportText.fraction(done) == 1)
        let again = ImportJob(id: "x", source: "csv", status: .done, counts: .init(unchanged: 50))
        #expect(ImportText.summary(again, locale: ar) == "لا جديد: كل شيء موجود في زمام.")

        #expect(ImportText.countRows(done.counts).map(\.label) == ["أُضيف", "حُدِّث"])
        #expect(ImportText.countRows(.init()).map(\.value) == [0])
    }

    @Test func countedItemsAgreeWithTheNumber() {
        #expect(ImportText.items(1, locale: ar) == "عنصر واحد")
        #expect(ImportText.items(2, locale: ar) == "عنصران")
        #expect(ImportText.items(7, locale: ar) == "٧ عناصر")
        #expect(ImportText.items(48, locale: ar) == "٤٨ عنصراً")
        #expect(ImportText.items(100, locale: ar) == "١٠٠ عنصر")
    }

    @Test func fileChecksMatchTheServer() {
        let csv = ImportSource(id: "todoist-csv", label: "Todoist", input: .file, extensions: [".csv"])
        let max = 5 * 1024 * 1024
        #expect(ImportText.check(fileName: "مشروع.CSV", size: 1200, source: csv, maxFileBytes: max) == nil)
        #expect(ImportText.check(fileName: "Tasks.json", size: 1200, source: csv, maxFileBytes: max) == .wrongType(expected: [".csv"]))
        #expect(ImportText.check(fileName: "a.csv", size: 0, source: csv, maxFileBytes: max) == .empty)
        #expect(ImportText.check(fileName: "a.csv", size: max + 1, source: csv, maxFileBytes: max) == .tooLarge(maxBytes: max))
        // No extension: the server accepts it and reads the content.
        #expect(ImportText.check(fileName: "export", size: 10, source: csv, maxFileBytes: max) == nil)

        #expect(ImportText.size(max, locale: ar) == "٥ ميغابايت")
        #expect(ImportText.message(for: .wrongType(expected: [".csv", ".tsv"]), locale: ar) == "هذا المصدر يقبل ملفات CSV أو TSV فقط.")
        #expect(ImportText.message(for: .tooLarge(maxBytes: max), locale: ar).contains("٥ ميغابايت"))
    }

    @Test func apiErrorsReadInArabic() {
        let busy = APIError(status: 409, code: "import_in_progress", message: "Another import is still running")
        #expect(ImportText.message(for: busy) == "يجري استيراد آخر الآن. انتظر حتى ينتهي ثم ابدأ استيراداً جديداً.")
        let large = APIError(status: 413, code: "file_too_large", message: "Files up to 5 MB")
        #expect(ImportText.message(for: large, maxFileBytes: 5 * 1024 * 1024, locale: ar).contains("٥ ميغابايت"))
        #expect(ImportText.message(for: URLError(.notConnectedToInternet)) == "تعذّر الاتصال بزمام. تحقّق من الإنترنت وحاول مرة أخرى.")
    }

    @Test func multipartBodyHasTheSourceAndTheFile() {
        var form = MultipartForm(boundary: "B")
        form.addField("source", "todoist-csv")
        form.addFile("file", fileName: "مشروع \"أ\".csv", mimeType: "text/csv", data: Data("TYPE,CONTENT\n".utf8))
        let text = String(decoding: form.data, as: UTF8.self)
        #expect(form.contentType == "multipart/form-data; boundary=B")
        #expect(text == """
        --B\r
        Content-Disposition: form-data; name="source"\r
        \r
        todoist-csv\r
        --B\r
        Content-Disposition: form-data; name="file"; filename="مشروع 'أ'.csv"\r
        Content-Type: text/csv\r
        \r
        TYPE,CONTENT
        \r
        --B--\r

        """)
        #expect(MultipartForm.mimeType(forFileName: "Tasks.JSON") == "application/json")
    }
}

struct AppleRemindersImportTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    // 2026-10-13 12:00 in Riyadh.
    let now = Date(timeIntervalSince1970: 1_791_882_000)
    let home = AppleRemindersImport.List(id: "L1", title: "البيت")
    let work = AppleRemindersImport.List(id: "L2", title: "العمل")

    @Test func priorityFollowsReminders() {
        #expect(AppleRemindersImport.priority(fromEventKit: 0) == TaskPriority.none)
        #expect(AppleRemindersImport.priority(fromEventKit: 1) == .high)
        #expect(AppleRemindersImport.priority(fromEventKit: 5) == .medium)
        #expect(AppleRemindersImport.priority(fromEventKit: 9) == .low)
    }

    @Test func dueDayAndTime() {
        let day = DateComponents(year: 2026, month: 10, day: 20)
        #expect(AppleRemindersImport.due(day, timeZone: riyadh)?.day == "2026-10-20")
        #expect(AppleRemindersImport.due(day, timeZone: riyadh)?.time == nil)

        // Floating time: read as local.
        let floating = DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 30)
        #expect(AppleRemindersImport.due(floating, timeZone: riyadh)?.time == "09:30")

        // A time with its own zone moves to the user's: 23:30 UTC is 02:30 the next day in Riyadh.
        var fixed = DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 30)
        fixed.timeZone = TimeZone(identifier: "UTC")
        let moved = AppleRemindersImport.due(fixed, timeZone: riyadh)
        #expect(moved?.day == "2026-10-21")
        #expect(moved?.time == "02:30")

        #expect(AppleRemindersImport.due(DateComponents(hour: 9), timeZone: riyadh) == nil)
    }

    @Test func listsBecomeProjectsAndRemindersBecomeTasks() {
        let items = [
            AppleRemindersImport.Item(externalId: "r1", listId: "L1", title: "  شراء الخبز ", notes: "من المخبز",
                                      due: DateComponents(year: 2026, month: 10, day: 14, hour: 8, minute: 0), priority: 1,
                                      alarms: [now.addingTimeInterval(3600), now.addingTimeInterval(-3600)]),
            AppleRemindersImport.Item(externalId: "r2", listId: "L1", title: "دفع الفاتورة", isCompleted: true,
                                      completedAt: Date(timeIntervalSince1970: 1_791_800_000), alarms: [now.addingTimeInterval(60)]),
            AppleRemindersImport.Item(externalId: "r3", listId: "L2", title: "اجتماع أسبوعي",
                                      due: DateComponents(year: 2026, month: 10, day: 15),
                                      repeatRule: .init(frequency: .weekly, interval: 2, weekdays: [.thursday, .monday])),
            AppleRemindersImport.Item(externalId: "r4", listId: "L2", title: "   "),
            AppleRemindersImport.Item(externalId: "r5", listId: "L3", title: "في قائمة لم تُختر"),
        ]
        let plan = AppleRemindersImport.plan(items: items, lists: [home, work], knownTasks: [:], knownProjects: [:],
                                             timeZone: riyadh, now: now, firstProjectSortOrder: 3)
        #expect(plan.projects.map(\.name) == ["البيت", "العمل"])
        #expect(plan.projects.map(\.sortOrder) == [3, 4])
        #expect(plan.tasks.count == 3)
        #expect(plan.untitled == 1)

        let bread = plan.tasks[0]
        #expect(bread.title == "شراء الخبز")
        #expect(bread.notes == "من المخبز")
        #expect(bread.projectId == plan.projects[0].id)
        #expect(bread.dueDate == "2026-10-14")
        #expect(bread.dueTime == "08:00")
        #expect(bread.priority == .high)
        #expect(bread.status == .todo)

        let bill = plan.tasks[1]
        #expect(bill.status == .done)
        #expect(bill.completedAt == 1_791_800_000_000)

        let meeting = plan.tasks[2]
        #expect(meeting.projectId == plan.projects[1].id)
        #expect(meeting.recurrence == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH")

        // Only the future alarm of the open task becomes a reminder.
        #expect(plan.reminders.count == 1)
        #expect(plan.reminders[0].taskId == bread.id)
        #expect(plan.reminders[0].kind == .time)

        #expect(plan.taskRefs["r1"] == bread.id)
        #expect(plan.projectRefs["L2"] == plan.projects[1].id)
        #expect(AppleRemindersImport.summary(plan, locale: Locale(identifier: "ar-SA")) == "أُضيفت ٣ مهام. وتُرك ما لا عنوان له: ١.")
    }

    @Test func reimportSkipsWhatWasImportedAndReusesTheProject() {
        let project = UUID()
        let items = [
            AppleRemindersImport.Item(externalId: "r1", listId: "L1", title: "شراء الخبز"),
            AppleRemindersImport.Item(externalId: "r6", listId: "L1", title: "غسل السيارة"),
            AppleRemindersImport.Item(externalId: "r6", listId: "L1", title: "غسل السيارة"),
        ]
        let plan = AppleRemindersImport.plan(items: items, lists: [home], knownTasks: ["r1": UUID()], knownProjects: ["L1": project],
                                             timeZone: riyadh, now: now)
        #expect(plan.projects.isEmpty)
        #expect(plan.tasks.map(\.title) == ["غسل السيارة"])
        #expect(plan.tasks[0].projectId == project)
        #expect(plan.alreadyImported == 2)
    }

    @Test func siriRemindersGoToTheInboxWithTheSameIdOnEveryDevice() {
        let user = UUID()
        let items = [
            AppleRemindersImport.Item(externalId: "s1", listId: "L1", title: "أتصل بأبي بعد العصر بكرة"),
            AppleRemindersImport.Item(externalId: "s2", listId: "L1", title: "أشتري خبز",
                                      due: DateComponents(year: 2026, month: 10, day: 14, hour: 18, minute: 0)),
        ]
        let bridge = AppleRemindersImport.BridgeOptions(userId: user)
        let plan = AppleRemindersImport.plan(items: items, lists: [home], knownTasks: [:], knownProjects: [:],
                                             timeZone: riyadh, now: now, bridge: bridge)
        #expect(plan.projects.isEmpty)
        #expect(plan.tasks.allSatisfy { $0.projectId == nil })

        let call = plan.tasks[0]
        #expect(call.title == "أتصل بأبي")
        #expect(call.duePrayer == .asr)
        #expect(call.duePrayerOffset == 0)
        #expect(call.dueDate == "2026-10-14")
        #expect(call.dueTime == nil)
        #expect(call.id == AppleRemindersImport.bridgedTaskId(userId: user, externalId: "s1"))

        // A time Reminders set is kept, and the title is left as it is.
        let bread = plan.tasks[1]
        #expect(bread.title == "أشتري خبز")
        #expect(bread.dueTime == "18:00")

        let again = AppleRemindersImport.plan(items: items, lists: [home], knownTasks: [:], knownProjects: [:],
                                              timeZone: riyadh, now: now, bridge: bridge)
        #expect(again.tasks.map(\.id) == plan.tasks.map(\.id))
        #expect(AppleRemindersImport.bridgedTaskId(userId: UUID(), externalId: "s1") != call.id)
    }

    @Test func rulesZimamCannotExpressAreNotedAndLongTitlesKept() {
        let long = String(repeating: "م", count: 600)
        let items = [
            AppleRemindersImport.Item(externalId: "r1", listId: "L1", title: long, url: URL(string: "https://zimam.work"),
                                      due: DateComponents(year: 2026, month: 10, day: 1),
                                      repeatRule: .init(frequency: .monthly, isExact: false)),
        ]
        let plan = AppleRemindersImport.plan(items: items, lists: [home], knownTasks: [:], knownProjects: [:], timeZone: riyadh, now: now)
        let task = plan.tasks[0]
        #expect(task.title.count == 500)
        #expect(task.recurrence == nil)
        #expect(task.notes?.hasPrefix(long) ?? false)
        #expect(task.notes?.contains("https://zimam.work") ?? false)
        #expect(task.notes?.contains("لا يدعمها زمام") ?? false)
    }
}
