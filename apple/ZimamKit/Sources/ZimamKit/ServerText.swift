import Foundation

/// The server's length limits on what people type (api/src/data/schemas.ts), and cutting text to
/// them. The server counts code points, so a letter with its marks («بِسْمِ») or an emoji built of
/// several is more than one; these count UTF-16 units, never fewer, so what fits here fits there.
/// A cut falls between whole characters, so a mark never parts from its letter. Without this, a
/// long title the device kept would be refused when it syncs, and stay on that device alone.
public enum ServerText {
    /// A task's title.
    public static let maxTitle = 500
    /// A task's notes.
    public static let maxNotes = 20_000
    /// A project's or a place's name.
    public static let maxName = 200
    /// A section's name.
    public static let maxSectionName = 100
    /// A task's tags: at most this many, each at most `maxTagLength`.
    public static let maxTags = 30
    public static let maxTagLength = 50

    /// Tags as the server takes them: trimmed, blanks left out, each cut to `maxTagLength`, and no
    /// more than `maxTags`. The server refuses the whole task otherwise, and with it a title or
    /// notes edited in the same save.
    public static func tags(_ tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            let cut = clip(trimmed, to: maxTagLength).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cut.isEmpty else { continue }
            result.append(cut)
            if result.count == maxTags { break }
        }
        return result
    }

    /// Whether the server may count `text` as longer than `limit`.
    public static func exceeds(_ text: String, _ limit: Int) -> Bool {
        text.utf16.count > limit
    }

    /// The longest start of `text`, in whole characters, within `limit`.
    public static func clip(_ text: String, to limit: Int) -> String {
        guard exceeds(text, limit) else { return text }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let width = text[index].utf16.count
            if used + width > limit { break }
            used += width
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
