import XCTest
@testable import ZimamKit

final class ImportsTests: XCTestCase {
    let ar = Locale(identifier: "ar-SA")

    func testDecodesSourcesInTheServerShape() throws {
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
        XCTAssertEqual(sources.maxFileBytes, 5_242_880)
        XCTAssertEqual(sources.sources.map(\.id), ["todoist-csv", "todoist-api", "csv", "trello", "pigeon"])
        XCTAssertEqual(sources.sources[0].input, .file)
        XCTAssertEqual(sources.sources[1].input, .token)
        XCTAssertEqual(sources.sources[1].extensions, [])
        XCTAssertEqual(sources.sources[2].extensions, [".csv", ".tsv", ".txt"])
        // Without `available` (older servers), a source can start.
        XCTAssertTrue(sources.sources[0].available)
        XCTAssertEqual(sources.sources[3].input, .oauth)
        XCTAssertFalse(sources.sources[3].available)
        // A kind of source this version cannot start is kept apart, not a decoding error.
        XCTAssertEqual(sources.sources[4].input, .unsupported)
    }

    func testReadsTheOAuthCallback() throws {
        let id = "Zk3_q-8vXc1Lr0aT9yUeWb2NpHs4MdFg7jK6oQiAxYz"
        XCTAssertEqual(ImportCallback(url: try XCTUnwrap(URL(string: "zimam://import-callback?pending=\(id)&source=notion"))),
                       .pending(ImportCallback.Pending(id: id, source: "notion", token: nil)))
        // Trello's token comes in the fragment, never the query.
        let trello = "ATTA0123456789abcdef0123456789abcdef"
        XCTAssertEqual(ImportCallback(url: try XCTUnwrap(URL(string: "zimam://import-callback?pending=\(id)&source=trello#token=\(trello)"))),
                       .pending(ImportCallback.Pending(id: id, source: "trello", token: trello)))
        XCTAssertEqual(ImportCallback(url: try XCTUnwrap(URL(string: "zimam://import-callback?pending=\(id)&source=Not%20One"))),
                       .pending(ImportCallback.Pending(id: id, source: nil, token: nil)))
        XCTAssertEqual(ImportCallback(url: try XCTUnwrap(URL(string: "zimam://import-callback?error=denied"))), .failure("denied"))
        XCTAssertNil(ImportCallback(url: try XCTUnwrap(URL(string: "zimam://import-callback?pending=short"))))
        // A job id in the link starts nothing: only the server's confirm does.
        XCTAssertNil(ImportCallback(url: try XCTUnwrap(URL(string: "zimam://import-callback?job=0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f"))))
        XCTAssertNil(ImportCallback(url: try XCTUnwrap(URL(string: "zimam://join/ABC"))))
        XCTAssertNil(ImportCallback(url: try XCTUnwrap(URL(string: "https://example.com/import-callback?pending=\(id)"))))
        XCTAssertEqual(ImportText.connect(ImportSource(id: "notion", label: "Notion", input: .oauth)), "الربط بـ Notion")
        XCTAssertTrue(ImportText.oauthMessage("denied").hasPrefix("لم يكتمل الإذن"))
        XCTAssertEqual(ImportText.title(forSource: "ticktick-api", label: "TickTick"), "TickTick: الربط بالحساب")
    }

    func testAsksBeforeImportingIntoTheSignedInAccount() {
        let account = ImportText.accountLabel(name: "فهد", email: "fahad@example.com")
        XCTAssertEqual(account, "فهد، fahad@example.com")
        XCTAssertEqual(ImportText.accountLabel(name: " ", email: nil), nil)
        XCTAssertEqual(ImportText.confirmQuestion(source: "notion", account: account), "استيراد بيانات Notion إلى حسابك فهد، fahad@example.com؟")
        XCTAssertEqual(ImportText.confirmQuestion(source: nil, account: nil), "استيراد البيانات إلى حسابك؟")
        XCTAssertTrue(ImportText.confirmMessage(for: APIError(status: 404, code: "not_found", message: "")).contains("لا يخص حسابك"))
        XCTAssertTrue(ImportText.confirmMessage(for: APIError(status: 410, code: "expired", message: "")).contains("استُعمل من قبل"))
    }

    func testDecodesAJobWithCountsWarningsAndErrors() throws {
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
        XCTAssertEqual(job.id, "0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f")
        XCTAssertEqual(job.status, .running)
        XCTAssertFalse(job.isFinished)
        XCTAssertEqual(job.fileName, "زواج.csv")
        XCTAssertEqual(job.progress, ImportJob.Progress(processed: 50, total: 121))
        XCTAssertEqual(job.counts, ImportJob.Counts(created: 48, failed: 2))
        XCTAssertEqual(job.warnings.count, 1)
        XCTAssertEqual(job.errors.first?.entity, "task")
        XCTAssertNil(job.error)
        XCTAssertNil(job.finishedAt)
        XCTAssertEqual(ImportText.progress(job, locale: ar), "٥٠ من ١٢١")
        XCTAssertEqual(ImportText.fraction(job) ?? 0, 50.0 / 121.0, accuracy: 0.0001)
    }

    func testDecodesAFailedJobAndAJobList() throws {
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
        XCTAssertEqual(jobs[0].status, .failed)
        XCTAssertTrue(jobs[0].isFinished)
        XCTAssertEqual(jobs[0].error?.code, "token_rejected")
        XCTAssertEqual(ImportText.summary(jobs[0], locale: ar), "رفض Todoist الرمز. انسخه مرة أخرى.")
        // An unknown status keeps being followed rather than read as finished.
        XCTAssertEqual(jobs[1].status, .running)
    }

    func testProgressAndSummaryText() {
        let queued = ImportJob(id: "x", source: "csv", status: .queued)
        XCTAssertEqual(ImportText.progress(queued, locale: ar), "ينتظر دوره في الطابور…")
        XCTAssertNil(ImportText.fraction(queued))
        let reading = ImportJob(id: "x", source: "csv", status: .running)
        XCTAssertEqual(ImportText.progress(reading, locale: ar), "تُقرأ البيانات…")

        let done = ImportJob(id: "x", source: "csv", status: .done, progress: .init(processed: 50, total: 50),
                             counts: .init(created: 48, updated: 2))
        XCTAssertEqual(ImportText.summary(done, locale: ar), "أُضيف ٤٨ عنصراً، وحُدِّث عنصران.")
        XCTAssertEqual(ImportText.fraction(done), 1)
        let again = ImportJob(id: "x", source: "csv", status: .done, counts: .init(unchanged: 50))
        XCTAssertEqual(ImportText.summary(again, locale: ar), "لا جديد: كل شيء موجود في زمام.")

        XCTAssertEqual(ImportText.countRows(done.counts).map(\.label), ["أُضيف", "حُدِّث"])
        XCTAssertEqual(ImportText.countRows(.init()).map(\.value), [0])
    }

    func testCountedItemsAgreeWithTheNumber() {
        XCTAssertEqual(ImportText.items(1, locale: ar), "عنصر واحد")
        XCTAssertEqual(ImportText.items(2, locale: ar), "عنصران")
        XCTAssertEqual(ImportText.items(7, locale: ar), "٧ عناصر")
        XCTAssertEqual(ImportText.items(48, locale: ar), "٤٨ عنصراً")
        XCTAssertEqual(ImportText.items(100, locale: ar), "١٠٠ عنصر")
    }

    func testFileChecksMatchTheServer() {
        let csv = ImportSource(id: "todoist-csv", label: "Todoist", input: .file, extensions: [".csv"])
        let max = 5 * 1024 * 1024
        XCTAssertNil(ImportText.check(fileName: "مشروع.CSV", size: 1200, source: csv, maxFileBytes: max))
        XCTAssertEqual(ImportText.check(fileName: "Tasks.json", size: 1200, source: csv, maxFileBytes: max), .wrongType(expected: [".csv"]))
        XCTAssertEqual(ImportText.check(fileName: "a.csv", size: 0, source: csv, maxFileBytes: max), .empty)
        XCTAssertEqual(ImportText.check(fileName: "a.csv", size: max + 1, source: csv, maxFileBytes: max), .tooLarge(maxBytes: max))
        // No extension: the server accepts it and reads the content.
        XCTAssertNil(ImportText.check(fileName: "export", size: 10, source: csv, maxFileBytes: max))

        XCTAssertEqual(ImportText.size(max, locale: ar), "٥ ميغابايت")
        XCTAssertEqual(ImportText.message(for: .wrongType(expected: [".csv", ".tsv"]), locale: ar), "هذا المصدر يقبل ملفات CSV أو TSV فقط.")
        XCTAssertTrue(ImportText.message(for: .tooLarge(maxBytes: max), locale: ar).contains("٥ ميغابايت"))
    }

    func testAPIErrorsReadInArabic() {
        let busy = APIError(status: 409, code: "import_in_progress", message: "Another import is still running")
        XCTAssertEqual(ImportText.message(for: busy), "يجري استيراد آخر الآن. انتظر حتى ينتهي ثم ابدأ استيراداً جديداً.")
        let large = APIError(status: 413, code: "file_too_large", message: "Files up to 5 MB")
        XCTAssertTrue(ImportText.message(for: large, maxFileBytes: 5 * 1024 * 1024, locale: ar).contains("٥ ميغابايت"))
        XCTAssertEqual(ImportText.message(for: URLError(.notConnectedToInternet)), "تعذّر الاتصال بزمام. تحقّق من الإنترنت وحاول مرة أخرى.")
    }

    func testMultipartBodyHasTheSourceAndTheFile() {
        var form = MultipartForm(boundary: "B")
        form.addField("source", "todoist-csv")
        form.addFile("file", fileName: "مشروع \"أ\".csv", mimeType: "text/csv", data: Data("TYPE,CONTENT\n".utf8))
        let text = String(decoding: form.data, as: UTF8.self)
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=B")
        XCTAssertEqual(text, """
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
        XCTAssertEqual(MultipartForm.mimeType(forFileName: "Tasks.JSON"), "application/json")
    }
}

final class AppleRemindersImportTests: XCTestCase {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    // 2026-10-13 12:00 in Riyadh.
    let now = Date(timeIntervalSince1970: 1_791_882_000)
    let home = AppleRemindersImport.List(id: "L1", title: "البيت")
    let work = AppleRemindersImport.List(id: "L2", title: "العمل")

    func testPriorityFollowsReminders() {
        XCTAssertEqual(AppleRemindersImport.priority(fromEventKit: 0), TaskPriority.none)
        XCTAssertEqual(AppleRemindersImport.priority(fromEventKit: 1), .high)
        XCTAssertEqual(AppleRemindersImport.priority(fromEventKit: 5), .medium)
        XCTAssertEqual(AppleRemindersImport.priority(fromEventKit: 9), .low)
    }

    func testDueDayAndTime() {
        let day = DateComponents(year: 2026, month: 10, day: 20)
        XCTAssertEqual(AppleRemindersImport.due(day, timeZone: riyadh)?.day, "2026-10-20")
        XCTAssertNil(AppleRemindersImport.due(day, timeZone: riyadh)?.time)

        // Floating time: read as local.
        let floating = DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 30)
        XCTAssertEqual(AppleRemindersImport.due(floating, timeZone: riyadh)?.time, "09:30")

        // A time with its own zone moves to the user's: 23:30 UTC is 02:30 the next day in Riyadh.
        var fixed = DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 30)
        fixed.timeZone = TimeZone(identifier: "UTC")
        let moved = AppleRemindersImport.due(fixed, timeZone: riyadh)
        XCTAssertEqual(moved?.day, "2026-10-21")
        XCTAssertEqual(moved?.time, "02:30")

        XCTAssertNil(AppleRemindersImport.due(DateComponents(hour: 9), timeZone: riyadh))
    }

    func testListsBecomeProjectsAndRemindersBecomeTasks() {
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
        XCTAssertEqual(plan.projects.map(\.name), ["البيت", "العمل"])
        XCTAssertEqual(plan.projects.map(\.sortOrder), [3, 4])
        XCTAssertEqual(plan.tasks.count, 3)
        XCTAssertEqual(plan.untitled, 1)

        let bread = plan.tasks[0]
        XCTAssertEqual(bread.title, "شراء الخبز")
        XCTAssertEqual(bread.notes, "من المخبز")
        XCTAssertEqual(bread.projectId, plan.projects[0].id)
        XCTAssertEqual(bread.dueDate, "2026-10-14")
        XCTAssertEqual(bread.dueTime, "08:00")
        XCTAssertEqual(bread.priority, .high)
        XCTAssertEqual(bread.status, .todo)

        let bill = plan.tasks[1]
        XCTAssertEqual(bill.status, .done)
        XCTAssertEqual(bill.completedAt, 1_791_800_000_000)

        let meeting = plan.tasks[2]
        XCTAssertEqual(meeting.projectId, plan.projects[1].id)
        XCTAssertEqual(meeting.recurrence, "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH")

        // Only the future alarm of the open task becomes a reminder.
        XCTAssertEqual(plan.reminders.count, 1)
        XCTAssertEqual(plan.reminders[0].taskId, bread.id)
        XCTAssertEqual(plan.reminders[0].kind, .time)

        XCTAssertEqual(plan.taskRefs["r1"], bread.id)
        XCTAssertEqual(plan.projectRefs["L2"], plan.projects[1].id)
        XCTAssertEqual(AppleRemindersImport.summary(plan, locale: Locale(identifier: "ar-SA")),
                       "أُضيفت ٣ مهام. وتُرك ما لا عنوان له: ١.")
    }

    func testReimportSkipsWhatWasImportedAndReusesTheProject() {
        let project = UUID()
        let items = [
            AppleRemindersImport.Item(externalId: "r1", listId: "L1", title: "شراء الخبز"),
            AppleRemindersImport.Item(externalId: "r6", listId: "L1", title: "غسل السيارة"),
            AppleRemindersImport.Item(externalId: "r6", listId: "L1", title: "غسل السيارة"),
        ]
        let plan = AppleRemindersImport.plan(items: items, lists: [home], knownTasks: ["r1": UUID()], knownProjects: ["L1": project],
                                             timeZone: riyadh, now: now)
        XCTAssertTrue(plan.projects.isEmpty)
        XCTAssertEqual(plan.tasks.map(\.title), ["غسل السيارة"])
        XCTAssertEqual(plan.tasks[0].projectId, project)
        XCTAssertEqual(plan.alreadyImported, 2)
    }

    func testRulesZimamCannotExpressAreNotedAndLongTitlesKept() {
        let long = String(repeating: "م", count: 600)
        let items = [
            AppleRemindersImport.Item(externalId: "r1", listId: "L1", title: long, url: URL(string: "https://zimam.app"),
                                      due: DateComponents(year: 2026, month: 10, day: 1),
                                      repeatRule: .init(frequency: .monthly, isExact: false)),
        ]
        let plan = AppleRemindersImport.plan(items: items, lists: [home], knownTasks: [:], knownProjects: [:], timeZone: riyadh, now: now)
        let task = plan.tasks[0]
        XCTAssertEqual(task.title.count, 500)
        XCTAssertNil(task.recurrence)
        XCTAssertTrue(task.notes?.hasPrefix(long) ?? false)
        XCTAssertTrue(task.notes?.contains("https://zimam.app") ?? false)
        XCTAssertTrue(task.notes?.contains("لا يدعمها زمام") ?? false)
    }
}
