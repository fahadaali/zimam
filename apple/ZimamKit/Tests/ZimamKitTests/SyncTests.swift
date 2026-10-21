import Foundation
import Testing
@testable import ZimamKit

struct SyncTests {
    @Test func decodesPullResponseInTheServerShape() throws {
        let json = """
        {"changes":[
          {"entity":"task","id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","op":"upsert","data":{
            "id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","ownerId":"1f0e2d3c-4b5a-4968-8776-655443322110",
            "projectId":null,"sectionId":null,"parentId":null,"title":"مراجعة العقد","notes":null,"status":"todo",
            "priority":3,"tags":["عمل"],"dueDate":"2026-10-15","dueTime":null,"duePrayer":"maghrib","duePrayerOffset":20,
            "recurrence":null,"assigneeId":null,"sortOrder":0,"completedAt":null,"createdAt":1,"updatedAt":2}},
          {"entity":"project","id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","op":"delete"}
        ],"cursor":42,"hasMore":false}
        """
        let response = try JSONDecoder().decode(PullResponse.self, from: Data(json.utf8))
        #expect(response.cursor == 42)
        guard case .task(let task)? = response.changes[0].record else { Issue.record("expected a task"); return }
        #expect(task.title == "مراجعة العقد")
        #expect(task.priority == .high)
        #expect(task.duePrayer == .maghrib)
        #expect(response.changes[1].op == .delete)
        #expect(response.changes[1].record == nil)
    }

    @Test func encodesMutations() throws {
        let id = UUID()
        let task = TaskRecord(id: id, title: "شراء هدية", updatedAt: 1000)
        let upsert = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Mutation.upsert(.task(task)))) as! [String: Any]
        #expect((upsert["op"] as? String) == "upsert")
        #expect((upsert["entity"] as? String) == "task")
        let data = upsert["data"] as! [String: Any]
        #expect((data["title"] as? String) == "شراء هدية")
        #expect((data["updatedAt"] as? Int) == 1000)
        #expect((data["status"] as? String) == "todo")

        let delete = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Mutation.delete(.task, id: id, updatedAt: 2000))) as! [String: Any]
        #expect((delete["op"] as? String) == "delete")
        #expect((delete["id"] as? String) == id.uuidString)
        #expect((delete["updatedAt"] as? Int) == 2000)
    }

    @Test func relativeRemindersRoundTrip() throws {
        let reminder = ReminderRecord(taskId: UUID(), kind: .relative, offsetMinutes: -15, updatedAt: 1000)
        let data = try JSONEncoder().encode(Mutation.upsert(.reminder(reminder)))
        let sent = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let fields = sent["data"] as! [String: Any]
        #expect((fields["kind"] as? String) == "relative")
        #expect((fields["offsetMinutes"] as? Int) == -15)

        let json = """
        {"changes":[{"entity":"reminder","id":"\(reminder.id.uuidString)","op":"upsert","data":{
          "id":"\(reminder.id.uuidString)","taskId":"\(reminder.taskId.uuidString)","kind":"relative","at":null,
          "prayer":null,"offsetMinutes":-15,"location":null,"createdAt":1,"updatedAt":1000}}],"cursor":1,"hasMore":false}
        """
        let response = try JSONDecoder().decode(PullResponse.self, from: Data(json.utf8))
        guard case .reminder(let pulled)? = response.changes[0].record else { Issue.record("expected a reminder"); return }
        #expect(pulled.kind == .relative)
        #expect(pulled.offsetMinutes == -15)
    }

    @Test func startDateDecodesAndIsAlwaysSent() throws {
        let json = """
        {"id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","title":"رحلة إلى جدة","status":"todo","priority":0,"tags":[],
         "dueDate":"2026-10-11","startDate":"2026-10-09","sortOrder":0,"updatedAt":2}
        """
        let trip = try JSONDecoder().decode(TaskRecord.self, from: Data(json.utf8))
        #expect(trip.startDate == "2026-10-09")
        #expect(trip.dueDate == "2026-10-11")

        // Servers and records from before start dates decode with none.
        let legacy = try JSONDecoder().decode(TaskRecord.self, from: Data(#"{"id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","title":"x","status":"todo","priority":0,"tags":[],"sortOrder":0,"updatedAt":1}"#.utf8))
        #expect(legacy.startDate == nil)

        // null is sent, so clearing the start reaches the server (which keeps a missing one).
        let oneDay = TaskRecord(title: "x", dueDate: "2026-10-11", updatedAt: 3)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oneDay)) as! [String: Any]
        #expect(encoded["startDate"] is NSNull)
        #expect((encoded["dueDate"] as? String) == "2026-10-11")
        #expect(encoded["dueTime"] == nil, "other empty fields stay out as before")
        let spanned = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trip)) as! [String: Any]
        #expect((spanned["startDate"] as? String) == "2026-10-09")
        #expect(try JSONDecoder().decode(TaskRecord.self, from: JSONEncoder().encode(trip)) == trip)
    }

    @Test func projectViewsIncludeTheTimelineAndUnknownOnesReadAsList() throws {
        func project(_ view: String) throws -> ProjectRecord {
            let json = #"{"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","kind":"project","name":"م","view":"\#(view)","sortOrder":0,"updatedAt":1}"#
            return try JSONDecoder().decode(ProjectRecord.self, from: Data(json.utf8))
        }
        #expect(try project("timeline").view == .timeline)
        #expect(try project("kanban").view == .kanban)
        #expect(try project("someFutureView").view == .list)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try project("timeline"))) as! [String: Any]
        #expect((encoded["view"] as? String) == "timeline")

        // An unknown view goes back as it came, until the user picks one this build knows.
        var future = try project("someFutureView")
        let kept = try JSONSerialization.jsonObject(with: JSONEncoder().encode(future)) as! [String: Any]
        #expect((kept["view"] as? String) == "someFutureView")
        future.view = .kanban
        let chosen = try JSONSerialization.jsonObject(with: JSONEncoder().encode(future)) as! [String: Any]
        #expect((chosen["view"] as? String) == "kanban")
        #expect(APIClient.pullQuery(cursor: 0, limit: 500).contains(URLQueryItem(name: "include", value: "timeline,place,relative")))
    }

    @Test func decodesResultsWithLowercaseIds() throws {
        let json = #"[{"entity":"task","id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","status":"stale","message":"newer"}]"#
        let results = try JSONDecoder().decode([MutationResult].self, from: Data(json.utf8))
        #expect(results[0].status == .stale)
        #expect(results[0].uuid == UUID(uuidString: "0B9C6F8E-6F2C-4A4E-9A51-1D2C3B4A5E6F"))
    }

    @Test func settingsSendNullLocationSoSharingCanBeTurnedOff() throws {
        let off = User.Settings(timeZone: "Asia/Riyadh")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as! [String: Any]
        #expect(json["location"] is NSNull)
        #expect((json["timeZone"] as? String) == "Asia/Riyadh")

        let on = User.Settings(location: .init(latitude: 24.7, longitude: 46.7))
        let decoded = try JSONDecoder().decode(User.Settings.self, from: JSONEncoder().encode(on))
        #expect(decoded == on)
        // Older servers without the new fields still decode.
        let legacy = try JSONDecoder().decode(User.Settings.self, from: Data(#"{"calendar":"hijri","prayerMethod":"ummAlQura","weekStart":0}"#.utf8))
        #expect(legacy.location == nil)
    }

    @Test func arabicSearchFolding() {
        #expect(ArabicSearch.fold("مُراجَعة  العقد ١٢") == "مراجعه العقد 12")
        #expect(ArabicSearch.matches("مُراجَعة العقد مع الإدارة", query: "الاداره عقد"))
        #expect(!ArabicSearch.matches("شراء هدية", query: "عقد"))
        #expect(!ArabicSearch.matches("أي نص", query: "  "))
    }

    @Test func realtimeRequestUsesWebSocketSchemeAndSession() throws {
        let api = APIClient(baseURL: URL(string: "https://api.zimam.work")!) { "zs_token" }
        let request = try #require(api.realtimeRequest())
        #expect(request.url?.absoluteString == "wss://api.zimam.work/v1/realtime")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer zs_token")

        let local = APIClient(baseURL: URL(string: "http://localhost:8787")!) { "zs_token" }
        #expect(local.realtimeRequest()?.url?.absoluteString == "ws://localhost:8787/v1/realtime")

        let signedOut = APIClient(baseURL: URL(string: "https://api.zimam.work")!) { nil }
        #expect(signedOut.realtimeRequest() == nil)
    }

    @Test func realtimeMessages() {
        #expect(RealtimeMessage.changedSeq(#"{"type":"changed","seq":42}"#) == 42)
        #expect(RealtimeMessage.changedSeq("pong") == nil)
        #expect(RealtimeMessage.changedSeq(#"{"type":"other","seq":1}"#) == nil)
        #expect(RealtimeMessage.changedSeq(#"{"type":"changed"}"#) == nil)
    }
}
