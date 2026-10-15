import assert from "node:assert/strict";
import { test } from "node:test";
import {
  MAX_DAYS,
  barPlace,
  dayAtPointer,
  dragSpan,
  groupRows,
  headerMonths,
  monthSegments,
  pointerDelta,
  scaleCells,
  scrollFor,
  spanPatch,
  timelineRange,
} from "../public/app/lib/timeline.js";

const today = "2026-10-15"; // a Thursday

test("the range covers every span and today, padded, at least the zoom's minimum", () => {
  const range = timelineRange([{ start: "2026-10-10", end: "2026-10-20" }], today, { zoom: "day" });
  assert.equal(range.from, "2026-10-07");
  assert.equal(range.days, 28);
  assert.equal(range.to, "2026-11-03");
  const long = timelineRange([{ start: "2026-09-01", end: "2026-12-31" }], today, { zoom: "day" });
  assert.equal(long.from, "2026-08-29");
  assert.equal(long.to, "2027-01-03");
});

test("the week zoom draws whole weeks from the week's first day", () => {
  const range = timelineRange([], today, { zoom: "week", weekStart: 6 }); // Saturday
  assert.equal(range.from, "2026-10-03"); // the Saturday on or before 8 October
  assert.equal(range.days % 7, 0);
  assert.ok(range.days >= 84);
});

test("a far date never draws more than MAX_DAYS, and today stays in range", () => {
  const range = timelineRange([{ start: "2020-01-01", end: "2020-01-02" }], today, { zoom: "day" });
  assert.equal(range.days, MAX_DAYS);
  assert.ok(range.from <= today && today <= range.to);
});

test("a bar's place in days from the range start, logical (no direction)", () => {
  assert.deepEqual(barPlace({ start: "2026-10-15", end: "2026-10-17" }, "2026-10-10"), { start: 5, length: 3 });
  assert.deepEqual(barPlace({ start: "2026-10-08", end: "2026-10-08" }, "2026-10-10"), { start: -2, length: 1 });
});

test("month header segments in both calendars, primary first", () => {
  const greg = monthSegments("2026-10-30", 5, "gregorian");
  assert.deepEqual(greg.map((s) => [s.start, s.length]), [[0, 2], [2, 3]]);
  assert.equal(greg[0].label, "أكتوبر ٢٠٢٦م");
  assert.equal(greg[1].label, "نوفمبر ٢٠٢٦م");
  const [primary, other] = headerMonths("2026-10-30", 5, "hijri");
  assert.ok(primary[0].label.endsWith("هـ"));
  assert.ok(other[0].label.endsWith("م"));
  assert.equal(primary.reduce((n, s) => n + s.length, 0), 5);
});

test("scale cells: a day each with both calendars, or a week each", () => {
  const days = scaleCells("2026-10-14", 3, { zoom: "day", primary: "gregorian", today });
  assert.deepEqual(days.map((c) => c.label), ["١٤", "١٥", "١٦"]);
  assert.ok(days.every((c) => c.secondary));
  assert.deepEqual(days.map((c) => c.isToday), [false, true, false]);
  const weeks = scaleCells("2026-10-11", 14, { zoom: "week", primary: "gregorian", today });
  assert.equal(weeks.length, 2);
  assert.equal(weeks[0].label, "١١ – ١٧");
  assert.deepEqual(weeks.map((c) => [c.start, c.length, c.isToday]), [[0, 7, true], [7, 7, false]]);
});

test("the pointer's day: from the right edge in Arabic, from the left in a left-to-right page", () => {
  const track = { trackLeft: 100, trackRight: 540, dayWidth: 44 };
  assert.equal(dayAtPointer(539, { ...track, rtl: true }), 0);
  assert.equal(dayAtPointer(540 - 44 * 2 - 1, { ...track, rtl: true }), 2);
  assert.equal(dayAtPointer(101, { ...track, rtl: false }), 0);
  assert.equal(dayAtPointer(100 + 44 * 3 + 1, { ...track, rtl: false }), 3);
});

test("dragging toward the left is later in Arabic, earlier in a left-to-right page", () => {
  assert.equal(pointerDelta(500, 500 - 88, { dayWidth: 44, rtl: true }), 2);
  assert.equal(pointerDelta(500, 500 + 50, { dayWidth: 44, rtl: true }), -1);
  assert.equal(pointerDelta(500, 500 - 88, { dayWidth: 44, rtl: false }), -2);
  assert.equal(pointerDelta(500, 510, { dayWidth: 44, rtl: true }), 0);
});

test("moving and resizing a span; an end never passes the other", () => {
  const span = { start: "2026-10-10", end: "2026-10-12" };
  assert.deepEqual(dragSpan(span, "move", 3), { start: "2026-10-13", end: "2026-10-15" });
  assert.deepEqual(dragSpan(span, "start", -2), { start: "2026-10-08", end: "2026-10-12" });
  assert.deepEqual(dragSpan(span, "start", 5), { start: "2026-10-12", end: "2026-10-12" });
  assert.deepEqual(dragSpan(span, "end", -5), { start: "2026-10-10", end: "2026-10-10" });
  assert.deepEqual(dragSpan(span, "end", 1), { start: "2026-10-10", end: "2026-10-13" });
  assert.throws(() => dragSpan(span, "spin", 1), RangeError);
});

test("the PATCH for a new span leaves startDate out for a task that never had one", () => {
  const plain = { id: "a", dueDate: "2026-10-12", startDate: null };
  assert.deepEqual(spanPatch(plain, { start: "2026-10-14", end: "2026-10-14" }), { dueDate: "2026-10-14" });
  assert.deepEqual(spanPatch(plain, { start: "2026-10-10", end: "2026-10-12" }), { dueDate: "2026-10-12", startDate: "2026-10-10" });
  const span = { id: "b", dueDate: "2026-10-12", startDate: "2026-10-10" };
  assert.deepEqual(spanPatch(span, { start: "2026-10-12", end: "2026-10-12" }), { dueDate: "2026-10-12", startDate: null });
  assert.equal(spanPatch(span, { start: "2026-10-10", end: "2026-10-12" }), null);
  assert.deepEqual(spanPatch({ id: "c", dueDate: null }, { start: "2026-10-01", end: "2026-10-03" }), { dueDate: "2026-10-03", startDate: "2026-10-01" });
});

test("scrolling today to the middle: negative scrollLeft in right-to-left", () => {
  const opts = { dayWidth: 44, labelWidth: 176, viewport: 576 };
  assert.equal(scrollFor(10, { ...opts, rtl: true }), -(10 * 44 + 22 - 200));
  assert.equal(scrollFor(10, { ...opts, rtl: false }), 10 * 44 + 22 - 200);
  assert.equal(scrollFor(0, { ...opts, rtl: true }), 0);
});

test("rows by group: dated by start then due, undated last or left out", () => {
  const sections = [{ id: "none", name: "بلا قسم" }, { id: "s1", name: "التصميم" }, { id: "s2", name: "فارغ" }];
  const tasks = [
    { id: "b", sectionId: "s1", dueDate: "2026-10-20", startDate: "2026-10-12" },
    { id: "a", sectionId: "s1", dueDate: "2026-10-14", startDate: "2026-10-12" },
    { id: "u", sectionId: "s1", dueDate: null },
    { id: "c", sectionId: "gone", dueDate: "2026-10-01" },
    { id: "sub", sectionId: "s1", dueDate: "2026-10-01", parentId: "a" },
  ];
  const groupOf = (t) => t.sectionId ?? "none";
  const rows = groupRows(tasks, sections, groupOf);
  assert.deepEqual(rows.map((g) => [g.id, g.tasks.map((t) => t.id)]), [["none", ["c"]], ["s1", ["a", "b", "u"]]]);
  const dated = groupRows(tasks, sections, groupOf, { undated: false });
  assert.deepEqual(dated.map((g) => [g.id, g.tasks.map((t) => t.id)]), [["none", ["c"]], ["s1", ["a", "b"]]]);
});
