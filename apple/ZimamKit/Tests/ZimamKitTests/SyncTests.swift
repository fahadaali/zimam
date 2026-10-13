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

    func testDecodesResultsWithLowercaseIds() throws {
        let json = #"[{"entity":"task","id":"0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f","status":"stale","message":"newer"}]"#
        let results = try JSONDecoder().decode([MutationResult].self, from: Data(json.utf8))
        XCTAssertEqual(results[0].status, .stale)
        XCTAssertEqual(results[0].uuid, UUID(uuidString: "0B9C6F8E-6F2C-4A4E-9A51-1D2C3B4A5E6F"))
    }

    func testArabicSearchFolding() {
        XCTAssertEqual(ArabicSearch.fold("مُراجَعة  العقد ١٢"), "مراجعه العقد 12")
        XCTAssertTrue(ArabicSearch.matches("مُراجَعة العقد مع الإدارة", query: "الاداره عقد"))
        XCTAssertFalse(ArabicSearch.matches("شراء هدية", query: "عقد"))
        XCTAssertFalse(ArabicSearch.matches("أي نص", query: "  "))
    }
}
