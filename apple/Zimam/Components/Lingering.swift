import SwiftUI

/// Completed tasks that stay in a list for a second so the completion can be undone, then
/// leave it (design/README.md, «الحالات والحركة»). Each task has one timer: completing it again
/// restarts the second, so complete, undo, complete never lets the first timer cut it short.
@MainActor @Observable
final class Lingering {
    private static let delay: Duration = .seconds(ZimamMotion.linger)

    private(set) var ids: Set<UUID> = []
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Keeps `id` in the list for a second, then removes it with `animation`
    /// (nil under Reduce Motion).
    func hold(_ id: UUID, animation: Animation?) {
        timers[id]?.cancel()
        ids.insert(id)
        timers[id] = Task {
            do { try await Task.sleep(for: Self.delay) } catch { return }
            timers[id] = nil
            _ = withAnimation(animation) { ids.remove(id) }
        }
    }
}
