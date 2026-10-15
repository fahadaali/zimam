import XCTest
@testable import ZimamKit

final class ManualOrderTests: XCTestCase {
    func testInsertsBetweenNeighboursWithoutTouchingThem() {
        XCTAssertEqual(ManualOrder.inserting(at: 1, into: [1, 2, 3]), [1, 1.5, 2, 3])
        XCTAssertEqual(ManualOrder.inserting(at: 0, into: [1, 2]), [0, 1, 2])
        XCTAssertEqual(ManualOrder.inserting(at: 2, into: [1, 2]), [1, 2, 3])
    }

    func testEmptyListStartsAtOne() {
        XCTAssertEqual(ManualOrder.inserting(at: 0, into: []), [1])
        XCTAssertEqual(ManualOrder.inserting(at: 5, into: []), [1])
    }

    func testOutOfRangeIndexIsClamped() {
        XCTAssertEqual(ManualOrder.inserting(at: 9, into: [1, 2]), [1, 2, 3])
        XCTAssertEqual(ManualOrder.inserting(at: -3, into: [1, 2]), [0, 1, 2])
    }

    func testRenumbersWhenNeighboursAreEqual() {
        // Tasks never ordered by hand all have order 0.
        XCTAssertEqual(ManualOrder.inserting(at: 1, into: [0, 0, 0]), [1, 2, 3, 4])
    }

    func testRenumbersWhenThereIsNoRoomLeft() {
        let a = 1.0
        XCTAssertEqual(ManualOrder.inserting(at: 1, into: [a, a.nextUp]), [1, 2, 3])
    }

    func testEqualOrdersAwayFromTheNeighboursAreKept() {
        // Only the two neighbours matter.
        XCTAssertEqual(ManualOrder.inserting(at: 3, into: [0, 0, 1, 2]), [0, 0, 1, 1.5, 2])
    }

    func testMovesWithinAList() {
        // [a b c d]: a after c gives [b c a d].
        XCTAssertEqual(ManualOrder.moving(from: 0, to: 2, in: [1, 2, 3, 4]), [2, 3, 3.5, 4])
        // The last item to the front.
        XCTAssertEqual(ManualOrder.moving(from: 3, to: 0, in: [1, 2, 3, 4]), [0, 1, 2, 3])
        // A missing index changes nothing.
        XCTAssertEqual(ManualOrder.moving(from: 7, to: 0, in: [1, 2]), [1, 2])
    }

    func testStaysAscendingAndDistinctAfterManyInsertsAtTheSamePlace() {
        var orders: [Double] = [1, 2]
        for _ in 0..<200 {
            orders = ManualOrder.inserting(at: 1, into: orders)
            XCTAssertEqual(orders, orders.sorted())
            XCTAssertEqual(Set(orders).count, orders.count)
        }
    }

    func testAfterIsPastEveryOrder() {
        XCTAssertEqual(ManualOrder.after([]), 1)
        XCTAssertEqual(ManualOrder.after([3, 1, 2]), 4)
        XCTAssertEqual(ManualOrder.after([-4]), -3)
    }
}
