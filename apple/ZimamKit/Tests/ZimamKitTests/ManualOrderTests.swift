import Foundation
import Testing
@testable import ZimamKit

struct ManualOrderTests {
    @Test func insertsBetweenNeighboursWithoutTouchingThem() {
        #expect(ManualOrder.inserting(at: 1, into: [1, 2, 3]) == [1, 1.5, 2, 3])
        #expect(ManualOrder.inserting(at: 0, into: [1, 2]) == [0, 1, 2])
        #expect(ManualOrder.inserting(at: 2, into: [1, 2]) == [1, 2, 3])
    }

    @Test func emptyListStartsAtOne() {
        #expect(ManualOrder.inserting(at: 0, into: []) == [1])
        #expect(ManualOrder.inserting(at: 5, into: []) == [1])
    }

    @Test func outOfRangeIndexIsClamped() {
        #expect(ManualOrder.inserting(at: 9, into: [1, 2]) == [1, 2, 3])
        #expect(ManualOrder.inserting(at: -3, into: [1, 2]) == [0, 1, 2])
    }

    @Test func renumbersWhenNeighboursAreEqual() {
        // Tasks never ordered by hand all have order 0.
        #expect(ManualOrder.inserting(at: 1, into: [0, 0, 0]) == [1, 2, 3, 4])
    }

    @Test func renumbersWhenThereIsNoRoomLeft() {
        let a = 1.0
        #expect(ManualOrder.inserting(at: 1, into: [a, a.nextUp]) == [1, 2, 3])
    }

    @Test func equalOrdersAwayFromTheNeighboursAreKept() {
        // Only the two neighbours matter.
        #expect(ManualOrder.inserting(at: 3, into: [0, 0, 1, 2]) == [0, 0, 1, 1.5, 2])
    }

    @Test func movesWithinAList() {
        // [a b c d]: a after c gives [b c a d].
        #expect(ManualOrder.moving(from: 0, to: 2, in: [1, 2, 3, 4]) == [2, 3, 3.5, 4])
        // The last item to the front.
        #expect(ManualOrder.moving(from: 3, to: 0, in: [1, 2, 3, 4]) == [0, 1, 2, 3])
        // A missing index changes nothing.
        #expect(ManualOrder.moving(from: 7, to: 0, in: [1, 2]) == [1, 2])
    }

    @Test func staysAscendingAndDistinctAfterManyInsertsAtTheSamePlace() {
        var orders: [Double] = [1, 2]
        for _ in 0..<200 {
            orders = ManualOrder.inserting(at: 1, into: orders)
            #expect(orders == orders.sorted())
            #expect(Set(orders).count == orders.count)
        }
    }

    @Test func afterIsPastEveryOrder() {
        #expect(ManualOrder.after([]) == 1)
        #expect(ManualOrder.after([3, 1, 2]) == 4)
        #expect(ManualOrder.after([-4]) == -3)
    }
}
