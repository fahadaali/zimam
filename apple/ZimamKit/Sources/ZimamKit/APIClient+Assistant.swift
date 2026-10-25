import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The in-app assistant. It needs the server and saves nothing; errors come as
// `APIError` (see `AssistantProblem`).

public extension APIClient {
    // MARK: Assistant

    /// `POST /v1/assistant/parse`: reads a task from a sentence such as
    /// «ذكرني أراجع العقد بعد المغرب يوم الخميس». Nothing is saved.
    func suggestTask(from text: String, now: Date = Date(), timeZone: TimeZone = .current) async throws -> TaskSuggestion {
        struct Body: Encodable {
            let text: String
            let now: String
        }
        return try await send("POST", "v1/assistant/parse", body: Body(text: text, now: ReminderPlanner.isoString(from: now, timeZone: timeZone)))
    }

    /// `POST /v1/assistant/breakdown`: three to eight subtask titles for a task the server knows.
    func suggestSubtasks(for taskId: UUID) async throws -> [String] {
        struct Body: Encodable { let taskId: String }
        let response: SubtaskSuggestions = try await send("POST", "v1/assistant/breakdown",
                                                           body: Body(taskId: taskId.uuidString.lowercased()))
        return response.subtasks
    }

    /// `GET /v1/assistant/summary`: the summary of `day` ("2026-10-15"), today by default.
    func daySummary(day: String? = nil) async throws -> DaySummary {
        let query = day.map { [URLQueryItem(name: "date", value: $0)] } ?? []
        return try await send("GET", "v1/assistant/summary", query: query)
    }
}

extension APIClient {
    /// Ids in paths are lowercase, as the server stores them.
    static func path(_ id: UUID) -> String { id.uuidString.lowercased() }
}
