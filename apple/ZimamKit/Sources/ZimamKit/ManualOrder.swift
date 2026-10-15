import Foundation

/// Placing an item in a manually ordered list (tasks in a kanban column, sections in a board).
/// Lists sort by `sortOrder` ascending, and by creation time where two orders are equal.
public enum ManualOrder {
    /// The orders of a list after inserting one item at `index`.
    ///
    /// `orders` are the list's current orders, in display order, without the moved item.
    /// The result has one more element: the moved item's order at `index`, and the others
    /// as they were whenever there is room between the new neighbours, so only the moved
    /// item changes. When there is no room (equal neighbours, as in a list never ordered by
    /// hand where every order is 0) the whole list is renumbered 1, 2, 3…, and the caller
    /// saves every item whose order changed.
    public static func inserting(at index: Int, into orders: [Double]) -> [Double] {
        let index = min(max(index, 0), orders.count)
        let before = index > 0 ? orders[index - 1] : nil
        let after = index < orders.count ? orders[index] : nil
        if let order = between(before, after) {
            var result = orders
            result.insert(order, at: index)
            return result
        }
        return renumbered(count: orders.count + 1)
    }

    /// The orders after moving the item at `from` to position `to` of the same list.
    /// `to` counts positions in the list without the item, as `inserting(at:into:)` does.
    public static func moving(from: Int, to: Int, in orders: [Double]) -> [Double] {
        guard orders.indices.contains(from) else { return orders }
        var rest = orders
        rest.remove(at: from)
        return inserting(at: to, into: rest)
    }

    /// An order after every one of `orders`, for an item added at the end.
    public static func after(_ orders: [Double]) -> Double {
        (orders.max() ?? 0) + 1
    }

    /// 1, 2, 3… for a list of `count` items.
    public static func renumbered(count: Int) -> [Double] {
        (0..<max(count, 0)).map { Double($0 + 1) }
    }

    /// An order strictly between two neighbours, or nil when they leave no room.
    static func between(_ before: Double?, _ after: Double?) -> Double? {
        switch (before, after) {
        case (nil, nil):
            return 1
        case (let before?, nil):
            return before + 1
        case (nil, let after?):
            return after - 1
        case (let before?, let after?):
            let middle = before + (after - before) / 2
            return before < middle && middle < after ? middle : nil
        }
    }
}
