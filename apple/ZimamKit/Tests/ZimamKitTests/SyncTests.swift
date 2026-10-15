import XCTest
@testable import ZimamKit

final class SyncTests: XCTestCase {
    func testDecodesPullResponseInTheServerShape() throws {
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
        XCTAssertEqual(response.cursor, 42)
        guard case .task(let task)? = response.changes[0].record else { return XCTFail("expected a task") }
        XCTAssertEqual(task.title, "مراجعة العقد")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.duePrayer, .maghrib)
        XCTAssertEqual(response.changes[1].op, .delete)
        XCTAssertNil(response.changes[1].record)
    }

    func testEncodesMutations() throws {
        let id = UUID()
        let task = TaskRecord(id: id, title: "شراء هدية", updatedAt: 1000)
        let upsert = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Mutation.upsert(.task(task)))) as! [String: Any]
        XCTAssertEqual(upsert["op"] as? String, "upsert")
        XCTAssertEqual(upsert["entity"] as? String, "task")
        let data = upsert["data"] as! [String: Any]
        XCTAssertEqual(data["title"] as? String, "شراء هدية")
        XCTAssertEqual(data["updatedAt"] as? Int, 1000)
        XCTAssertEqual(data["status"] as? String, "todo")

        let delete = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Mutation.delete(.task, id: id, updatedAt: 2000))) as! [String: Any]
        XCTAssertEqual(delete["op"] as? String, "delete")
        XCTAssertEqual(delete["id"] as? String, id.uuidString)
        XCTAssertEqual(delete["updatedAt"] as? Int, 2000)
    }

    func testStartDateDecodesAndIsAlwaysSent() throws {
        let json = """
        {"id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","title":"رحلة إلى جدة","status":"todo","priority":0,"tags":[],
         "dueDate":"2026-10-11","startDate":"2026-10-09","sortOrder":0,"updatedAt":2}
        """
        let trip = try JSONDecoder().decode(TaskRecord.self, from: Data(json.utf8))
        XCTAssertEqual(trip.startDate, "2026-10-09")
        XCTAssertEqual(trip.dueDate, "2026-10-11")

        // Servers and records from before start dates decode with none.
        let legacy = try JSONDecoder().decode(TaskRecord.self, from: Data(#"{"id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","title":"x","status":"todo","priority":0,"tags":[],"sortOrder":0,"updatedAt":1}"#.utf8))
        XCTAssertNil(legacy.startDate)

        // null is sent, so clearing the start reaches the server (which keeps a missing one).
        let oneDay = TaskRecord(title: "x", dueDate: "2026-10-11", updatedAt: 3)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oneDay)) as! [String: Any]
        XCTAssertTrue(encoded["startDate"] is NSNull)
        XCTAssertEqual(encoded["dueDate"] as? String, "2026-10-11")
        XCTAssertNil(encoded["dueTime"], "other empty fields stay out as before")
        let spanned = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trip)) as! [String: Any]
        XCTAssertEqual(spanned["startDate"] as? String, "2026-10-09")
        XCTAssertEqual(try JSONDecoder().decode(TaskRecord.self, from: JSONEncoder().encode(trip)), trip)
    }

    func testProjectViewsIncludeTheTimelineAndUnknownOnesReadAsList() throws {
        func project(_ view: String) throws -> ProjectRecord {
            let json = #"{"id":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","kind":"project","name":"م","view":"\#(view)","sortOrder":0,"updatedAt":1}"#
            return try JSONDecoder().decode(ProjectRecord.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try project("timeline").view, .timeline)
        XCTAssertEqual(try project("kanban").view, .kanban)
        XCTAssertEqual(try project("someFutureView").view, .list)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try project("timeline"))) as! [String: Any]
        XCTAssertEqual(encoded["view"] as? String, "timeline")

        // An unknown view goes back as it came, until the user picks one this build knows.
        var future = try project("someFutureView")
        let kept = try JSONSerialization.jsonObject(with: JSONEncoder().encode(future)) as! [String: Any]
        XCTAssertEqual(kept["view"] as? String, "someFutureView")
        future.view = .kanban
        let chosen = try JSONSerialization.jsonObject(with: JSONEncoder().encode(future)) as! [String: Any]
        XCTAssertEqual(chosen["view"] as? String, "kanban")
        XCTAssertTrue(APIClient.pullQuery(cursor: 0, limit: 500).contains(URLQueryItem(name: "include", value: "timeline")))
    }

    func testDecodesResultsWithLowercaseIds() throws {
        let json = #"[{"entity":"task","id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","status":"stale","message":"newer"}]"#
        let results = try JSONDecoder().decode([MutationResult].self, from: Data(json.utf8))
        XCTAssertEqual(results[0].status, .stale)
        XCTAssertEqual(results[0].uuid, UUID(uuidString: "0B9C6F8E-6F2C-4A4E-9A51-1D2C3B4A5E6F"))
    }

    func testSettingsSendNullLocationSoSharingCanBeTurnedOff() throws {
        let off = User.Settings(timeZone: "Asia/Riyadh")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as! [String: Any]
        XCTAssertTrue(json["location"] is NSNull)
        XCTAssertEqual(json["timeZone"] as? String, "Asia/Riyadh")

        let on = User.Settings(location: .init(latitude: 24.7, longitude: 46.7))
        let decoded = try JSONDecoder().decode(User.Settings.self, from: JSONEncoder().encode(on))
        XCTAssertEqual(decoded, on)
        // Older servers without the new fields still decode.
        let legacy = try JSONDecoder().decode(User.Settings.self, from: Data(#"{"calendar":"hijri","prayerMethod":"ummAlQura","weekStart":0}"#.utf8))
        XCTAssertNil(legacy.location)
    }

    func testArabicSearchFolding() {
        XCTAssertEqual(ArabicSearch.fold("مُراجَعة  العقد ١٢"), "مراجعه العقد 12")
        XCTAssertTrue(ArabicSearch.matches("مُراجَعة العقد مع الإدارة", query: "الاداره عقد"))
        XCTAssertFalse(ArabicSearch.matches("شراء هدية", query: "عقد"))
        XCTAssertFalse(ArabicSearch.matches("أي نص", query: "  "))
    }

    func testRealtimeRequestUsesWebSocketSchemeAndSession() throws {
        let api = APIClient(baseURL: URL(string: "https://api.zimam.app")!) { "zs_token" }
        let request = try XCTUnwrap(api.realtimeRequest())
        XCTAssertEqual(request.url?.absoluteString, "wss://api.zimam.app/v1/realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer zs_token")

        let local = APIClient(baseURL: URL(string: "http://localhost:8787")!) { "zs_token" }
        XCTAssertEqual(local.realtimeRequest()?.url?.absoluteString, "ws://localhost:8787/v1/realtime")

        let signedOut = APIClient(baseURL: URL(string: "https://api.zimam.app")!) { nil }
        XCTAssertNil(signedOut.realtimeRequest())
    }

    func testRealtimeMessages() {
        XCTAssertEqual(RealtimeMessage.changedSeq(#"{"type":"changed","seq":42}"#), 42)
        XCTAssertNil(RealtimeMessage.changedSeq("pong"))
        XCTAssertNil(RealtimeMessage.changedSeq(#"{"type":"other","seq":1}"#))
        XCTAssertNil(RealtimeMessage.changedSeq(#"{"type":"changed"}"#))
    }
}
