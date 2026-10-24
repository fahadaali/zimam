import assert from "node:assert/strict";
import { test } from "node:test";
import { QUADRANTS, VISIBLE_ROWS, anchoredByFields, byUrgency, hiddenCount, isAnchored, leavesUrgent, moveToQuadrant, quadrantOf, quadrants } from "../public/app/lib/matrix.js";

const today = "2026-10-15";
const task = (id, { priority = 0, dueDate = null, startDate = null, status = "todo", ...rest } = {}) => ({ id, priority, dueDate, startDate, status, ...rest });

test("four quadrants in reading order: the first at the inline start", () => {
  assert.deepEqual(QUADRANTS.map((q) => q.title), ["مهم وعاجل", "مهم", "عاجل", "يوماً ما"]);
});

test("important is priority 2 or more; urgent is due by tomorrow, overdue included", () => {
  assert.equal(quadrantOf(task("a", { priority: 3, dueDate: today }), today), "urgent-important");
  assert.equal(quadrantOf(task("b", { priority: 2, dueDate: "2026-10-16" }), today), "urgent-important");
  assert.equal(quadrantOf(task("c", { priority: 2, dueDate: "2026-10-17" }), today), "important");
  assert.equal(quadrantOf(task("d", { priority: 2 }), today), "important");
  assert.equal(quadrantOf(task("e", { priority: 1, dueDate: "2026-10-01" }), today), "urgent");
  assert.equal(quadrantOf(task("f", { priority: 0, dueDate: "2026-10-16" }), today), "urgent");
  assert.equal(quadrantOf(task("g", { priority: 1, dueDate: "2026-11-01" }), today), "someday");
  assert.equal(quadrantOf(task("h"), today), "someday");
  assert.equal(quadrantOf(task("i", { priority: 3, dueDate: today, status: "done" }), today), null);
});

test("groups open top-level tasks and sorts each quadrant by due date, then priority", () => {
  const groups = quadrants(
    [
      task("late", { priority: 0, dueDate: "2026-10-10" }),
      task("soon", { priority: 3, dueDate: "2026-10-16" }),
      task("now", { priority: 2, dueDate: today }),
      task("plan", { priority: 2 }),
      task("plan-dated", { priority: 3, dueDate: "2026-12-01" }),
      task("sub", { priority: 3, dueDate: today, parentId: "x" }),
      task("done", { priority: 3, dueDate: today, status: "done" }),
      task("idea"),
    ],
    today,
  );
  assert.deepEqual(groups["urgent-important"].map((t) => t.id), ["now", "soon"]);
  assert.deepEqual(groups.important.map((t) => t.id), ["plan-dated", "plan"]);
  assert.deepEqual(groups.urgent.map((t) => t.id), ["late"]);
  assert.deepEqual(groups.someday.map((t) => t.id), ["idea"]);
  assert.ok(byUrgency(task("x", { priority: 3, dueDate: today }), task("y", { priority: 1, dueDate: today })) < 0);
});

test("moving into important sets medium priority; out of it lowers the priority to low", () => {
  assert.deepEqual(moveToQuadrant(task("a", { priority: 0 }), "important", today), { patch: { priority: 2 }, refused: false });
  assert.deepEqual(moveToQuadrant(task("b", { priority: 1 }), "important", today), { patch: { priority: 2 }, refused: false });
  assert.deepEqual(moveToQuadrant(task("c", { priority: 3 }), "important", today), { patch: {}, refused: false });
  assert.deepEqual(moveToQuadrant(task("d", { priority: 3 }), "someday", today), { patch: { priority: 1 }, refused: false });
});

test("moving into urgent dates the task today unless it is already due by tomorrow", () => {
  assert.deepEqual(moveToQuadrant(task("a"), "urgent", today).patch, { dueDate: today });
  assert.deepEqual(moveToQuadrant(task("b", { dueDate: "2026-11-01" }), "urgent", today).patch, { dueDate: today });
  assert.deepEqual(moveToQuadrant(task("c", { priority: 2, dueDate: "2026-11-01" }), "urgent-important", today).patch, { dueDate: today });
  assert.deepEqual(moveToQuadrant(task("d", { priority: 2, dueDate: "2026-10-16" }), "urgent", today).patch, { priority: 1 });
  // A span moves to end today, keeping its length (DaySpan.ending), as in the calendar.
  assert.deepEqual(moveToQuadrant(task("e", { dueDate: "2026-11-10", startDate: "2026-11-01" }), "urgent", today).patch, { dueDate: today, startDate: "2026-10-06" });
  assert.deepEqual(moveToQuadrant(task("f", { dueDate: "2026-11-10", startDate: "2026-10-01" }), "urgent", today).patch, { dueDate: today, startDate: "2026-09-05" });
  // Its time stays with it, as when a task moves to another day.
  assert.deepEqual(moveToQuadrant(task("g", { dueDate: "2026-11-10", dueTime: "09:00" }), "urgent", today).patch, { dueDate: today });
});

test("moving out of urgent clears a plain due day, and is refused when more is tied to it", () => {
  const plain = task("a", { priority: 3, dueDate: today });
  assert.equal(leavesUrgent(plain, "important", today), true);
  assert.deepEqual(moveToQuadrant(plain, "important", today, { anchored: false }), { patch: { dueDate: null }, refused: false });
  assert.deepEqual(moveToQuadrant(plain, "important", today, { anchored: true }), { patch: {}, refused: true });
  assert.deepEqual(moveToQuadrant(task("b", { dueDate: "2026-10-01" }), "someday", today, { anchored: true }), { patch: {}, refused: true });
  // Staying urgent: the due day is not touched, so the anchor does not matter.
  assert.equal(leavesUrgent(plain, "urgent", today), false);
  assert.deepEqual(moveToQuadrant(plain, "urgent", today, { anchored: true }), { patch: { priority: 1 }, refused: false });
  assert.throws(() => moveToQuadrant(task("d"), "nowhere", today), RangeError);
});

test("a due day is tied to a time, a prayer, a repeat, a start date or a reminder (Store.isAnchored)", () => {
  assert.equal(anchoredByFields(task("a", { dueDate: today })), false);
  for (const fields of [{ dueTime: "09:00" }, { duePrayer: "asr" }, { recurrence: "FREQ=DAILY" }, { startDate: "2026-10-10" }]) {
    assert.equal(anchoredByFields(task("b", { dueDate: today, ...fields })), true, JSON.stringify(fields));
    assert.equal(isAnchored(task("b", { dueDate: today, ...fields }), 0), true);
  }
  assert.equal(isAnchored(task("c", { dueDate: today }), 0), false);
  assert.equal(isAnchored(task("c", { dueDate: today }), 2), true);
  // A count that could not be read is the safe answer: tied.
  assert.equal(isAnchored(task("c", { dueDate: today }), null), true);
});

test("«+n أخرى» counts the rows past the visible ones", () => {
  assert.equal(hiddenCount(VISIBLE_ROWS, false), 0);
  assert.equal(hiddenCount(VISIBLE_ROWS + 2, false), 2);
  assert.equal(hiddenCount(VISIBLE_ROWS + 2, true), 0);
});
