import Foundation
import Testing
@testable import Zimam

/// «التالي» on the Lock Screen and the watch: the soonest time ahead today, whatever comes before
/// it in the Today order, and a timeline that asks again when a busy day does not fit.
@MainActor
struct GlanceSnapshotTests {
    let noon = Date(timeIntervalSince1970: 1_791_882_000)

    private func item(_ title: String, at minutes: Double? = nil, overdue: Bool = false) -> GlanceSnapshot.Item {
        GlanceSnapshot.Item(id: UUID(), title: title, prayerText: nil,
                            time: minutes.map { noon.addingTimeInterval($0 * 60) }, isOverdue: overdue)
    }

    private func snapshot(_ items: [GlanceSnapshot.Item]) -> GlanceSnapshot {
        GlanceSnapshot(isSignedIn: true, calendar: "hijri", day: "2026-10-13", openCount: items.count, doneCount: 0,
                       items: GlanceSnapshot.kept(items))
    }

    @Test func manyOverdueTasksDoNotHideTheNextTimedOne() {
        let overdue = (0..<12).map { item("متأخرة \($0)", overdue: true) }
        let meeting = item("اجتماع", at: 120)
        let glance = snapshot(overdue + [meeting])
        #expect(glance.next(at: noon)?.title == "اجتماع")
        // Past its time, the first in the Today order again.
        #expect(glance.next(at: noon.addingTimeInterval(3 * 3600))?.title == "متأخرة 0")
    }

    @Test func keepsTheFirstAndEveryTimedTask() {
        let kept = GlanceSnapshot.kept([item("أولى"), item("بلا وقت"), item("موعد", at: 30)])
        #expect(kept.map(\.title) == ["أولى", "موعد"])
    }

    @Test func aBusyDayReloadsAtItsLastEntry() {
        let times = (1...14).map { item("موعد \($0)", at: Double($0) * 10) }
        let glance = snapshot(times)
        let midnight = noon.addingTimeInterval(12 * 3600)
        let timeline = glance.timeline(from: noon, until: midnight)
        #expect(timeline.dates.count == 11)
        #expect(timeline.reload == noon.addingTimeInterval(100 * 60))

        let quiet = snapshot(Array(times.prefix(3))).timeline(from: noon, until: midnight)
        #expect(quiet.dates.count == 4)
        #expect(quiet.reload == midnight)
    }
}
