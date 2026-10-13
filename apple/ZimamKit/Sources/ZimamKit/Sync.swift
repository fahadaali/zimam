import Foundation

/// One record that changed on the server since the client's cursor.
public struct SyncChange: Decodable, Sendable {
    public enum Operation: String, Decodable, Sendable { case upsert, delete }

    public let entity: EntityKind
    public let id: UUID
    public let op: Operation
    /// The latest state; nil for deletes.
    public let record: AnyRecord?

    private enum CodingKeys: String, CodingKey { case entity, id, op, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entity = try c.decode(EntityKind.self, forKey: .entity)
        id = try c.decode(UUID.self, forKey: .id)
        op = try c.decode(Operation.self, forKey: .op)
        guard op == .upsert else {
            record = nil
            return
        }
        switch entity {
        case .project: record = .project(try c.decode(ProjectRecord.self, forKey: .data))
        case .section: record = .section(try c.decode(SectionRecord.self, forKey: .data))
        case .task: record = .task(try c.decode(TaskRecord.self, forKey: .data))
        case .reminder: record = .reminder(try c.decode(ReminderRecord.self, forKey: .data))
        case .comment: record = .comment(try c.decode(CommentRecord.self, forKey: .data))
        }
    }
}

public struct PullResponse: Decodable, Sendable {
    public let changes: [SyncChange]
    public let cursor: Int64
    public let hasMore: Bool
}

/// A local edit to send to the server.
public enum Mutation: Encodable, Sendable {
    case upsert(AnyRecord)
    case delete(EntityKind, id: UUID, updatedAt: Milliseconds)

    private enum CodingKeys: String, CodingKey { case op, entity, data, id, updatedAt }

    public var id: UUID {
        switch self {
        case .upsert(.project(let r)): r.id
        case .upsert(.section(let r)): r.id
        case .upsert(.task(let r)): r.id
        case .upsert(.reminder(let r)): r.id
        case .upsert(.comment(let r)): r.id
        case .delete(_, let id, _): id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upsert(let record):
            try c.encode("upsert", forKey: .op)
            try c.encode(record.kind, forKey: .entity)
            switch record {
            case .project(let r): try c.encode(r, forKey: .data)
            case .section(let r): try c.encode(r, forKey: .data)
            case .task(let r): try c.encode(r, forKey: .data)
            case .reminder(let r): try c.encode(r, forKey: .data)
            case .comment(let r): try c.encode(r, forKey: .data)
            }
        case .delete(let entity, let id, let updatedAt):
            try c.encode("delete", forKey: .op)
            try c.encode(entity, forKey: .entity)
            try c.encode(id, forKey: .id)
            try c.encode(updatedAt, forKey: .updatedAt)
        }
    }
}

public struct MutationResult: Decodable, Sendable {
    public enum Status: String, Decodable, Sendable {
        /// Saved.
        case applied
        /// The server has a newer version; the next pull brings it.
        case stale
        /// Deleted on the server.
        case gone
        case forbidden
        case invalid
    }

    public let entity: EntityKind?
    /// Lowercase id as the server echoes it.
    public let id: String?
    public let status: Status
    public let message: String?

    public var uuid: UUID? { id.flatMap(UUID.init(uuidString:)) }
}
