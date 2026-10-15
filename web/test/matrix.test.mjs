import assert from "node:assert/strict";
import { test } from "node:test";
import { QUADRANTS, VISIBLE_ROWS, byUrgency, hiddenCount, moveToQuadrant, quadrantOf, quadrants, todayIn } from "../public/app/lib/matrix.js";

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

test("today follows the user's time zone, not the device's", () => {
  // 22:30 UTC on 14 October is already 15 October in Riyadh (UTC+3) but not in Los Angeles.
  const now = new Date(Date.UTC(2026, 9, 14, 22, 30));
  assert.equal(todayIn("Asia/Riyadh", now), "2026-10-15");
  assert.equal(todayIn("America/Los_Angeles", now), "2026-10-14");
  assert.match(todayIn("Not/AZone", now), /^\d{4}-\d{2}-\d{2}$/);
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

test("moving into important sets medium priority; out of it clears the priority", () => {
  assert.deepEqual(moveToQuadrant(task("a", { priority: 0 }), "important", today), { patch: { priority: 2 }, clearsDueDate: false });
  assert.deepEqual(moveToQuadrant(task("b", { priority: 1 }), "important", today), { patch: { priority: 2 }, clearsDueDate: false });
  assert.deepEqual(moveToQuadrant(task("c", { priority: 3 }), "important", today), { patch: {}, clearsDueDate: false });
  assert.deepEqual(moveToQuadrant(task("d", { priority: 3 }), "someday", today), { patch: { priority: 0 }, clearsDueDate: false });
});

test("moving into urgent dates the task today unless it is already due by tomorrow", () => {
  assert.deepEqual(moveToQuadrant(task("a"), "urgent", today).patch, { dueDate: today });
  assert.deepEqual(moveToQuadrant(task("b", { dueDate: "2026-11-01" }), "urgent", today).patch, { dueDate: today });
  assert.deepEqual(moveToQuadrant(task("c", { priority: 2, dueDate: "2026-11-01" }), "urgent-important", today).patch, { dueDate: today });
  assert.deepEqual(moveToQuadrant(task("d", { priority: 2, dueDate: "2026-10-16" }), "urgent", today).patch, { priority: 0 });
  // A start date after the new due date would break the span, so it goes.
  assert.deepEqual(moveToQuadrant(task("e", { dueDate: "2026-11-10", startDate: "2026-11-01" }), "urgent", today).patch, { dueDate: today, startDate: null });
  assert.deepEqual(moveToQuadrant(task("f", { dueDate: "2026-11-10", startDate: "2026-10-01" }), "urgent", today).patch, { dueDate: today });
});

test("moving out of urgent clears the due date, and asks first", () => {
  assert.deepEqual(moveToQuadrant(task("a", { priority: 3, dueDate: today }), "important", today), { patch: { dueDate: null }, clearsDueDate: true });
  assert.deepEqual(moveToQuadrant(task("b", { dueDate: "2026-10-01", startDate: "2026-09-28" }), "someday", today), {
    patch: { dueDate: null, startDate: null },
    clearsDueDate: true,
  });
  assert.deepEqual(moveToQuadrant(task("c", { priority: 3, dueDate: today }), "urgent", today), { patch: { priority: 0 }, clearsDueDate: false });
  assert.throws(() => moveToQuadrant(task("d"), "nowhere", today), RangeError);
});

test("«+n أخرى» counts the rows past the visible ones", () => {
  assert.equal(hiddenCount(VISIBLE_ROWS, false), 0);
  assert.equal(hiddenCount(VISIBLE_ROWS + 2, false), 2);
  assert.equal(hiddenCount(VISIBLE_ROWS + 2, true), 0);
});
