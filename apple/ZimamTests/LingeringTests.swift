import Foundation
import Testing
@testable import Zimam

/// A completed task stays in its list for `ZimamMotion.linger`, and completing it again restarts
/// that time (Zimam/Components/Lingering.swift).
@MainActor
struct LingeringTests {
    @Test func holdKeepsTheTaskThenLetsItGo() async throws {
        let lingering = Lingering()
        let id = UUID()
        #expect(!lingering.contains(id))

        lingering.hold(id, animation: nil)
        #expect(lingering.contains(id))

        try await Task.sleep(for: .seconds(ZimamMotion.linger + 0.5))
        #expect(!lingering.contains(id))
    }

    @Test func holdingAgainRestartsTheTimer() async throws {
        let lingering = Lingering()
        let id = UUID()

        lingering.hold(id, animation: nil)
        try await Task.sleep(for: .seconds(ZimamMotion.linger * 0.6))
        #expect(lingering.contains(id))

        // Complete, undo, complete: the first timer must not cut the second hold short.
        lingering.hold(id, animation: nil)
        try await Task.sleep(for: .seconds(ZimamMotion.linger * 0.6))
        #expect(lingering.contains(id))

        try await Task.sleep(for: .seconds(ZimamMotion.linger))
        #expect(!lingering.contains(id))
    }

    @Test func eachTaskHasItsOwnTimer() async throws {
        let lingering = Lingering()
        let first = UUID()
        let second = UUID()

        lingering.hold(first, animation: nil)
        try await Task.sleep(for: .seconds(ZimamMotion.linger * 0.65))
        lingering.hold(second, animation: nil)
        try await Task.sleep(for: .seconds(ZimamMotion.linger * 0.65))

        #expect(!lingering.contains(first))
        #expect(lingering.contains(second))
    }
}
