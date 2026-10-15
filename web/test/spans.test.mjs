import assert from "node:assert/strict";
import { test } from "node:test";
import {
  checkStart,
  isMultiDay,
  rowBars,
  shiftTo,
  singleDayByDay,
  spanFields,
  spanLength,
  spanText,
  taskSpan,
  tasksByOccupiedDay,
} from "../public/app/lib/spans.js";

const task = (id, dueDate, startDate = null, extra = {}) => ({ id, title: id, dueDate, startDate, status: "todo", ...extra });

test("a task's span: start to due inclusive, or the due day alone", () => {
  assert.deepEqual(taskSpan(task("a", "2026-10-20", "2026-10-15")), { start: "2026-10-15", end: "2026-10-20" });
  assert.deepEqual(taskSpan(task("b", "2026-10-20")), { start: "2026-10-20", end: "2026-10-20" });
  assert.equal(taskSpan(task("c", null)), null);
  // A start date without a due date, or after it, is ignored (the server never stores either).
  assert.equal(taskSpan(task("d", null, "2026-10-15")), null);
  assert.deepEqual(taskSpan(task("e", "2026-10-15", "2026-10-20")), { start: "2026-10-15", end: "2026-10-15" });
  assert.equal(spanLength({ start: "2026-10-15", end: "2026-10-20" }), 6);
  assert.equal(isMultiDay(task("f", "2026-10-15", "2026-10-15")), false);
  assert.equal(isMultiDay(task("g", "2026-10-16", "2026-10-15")), true);
});

test("checks a start date against the due date", () => {
  assert.equal(checkStart("", "2026-10-20"), null);
  assert.equal(checkStart("2026-10-15", "2026-10-20"), null);
  assert.equal(checkStart("2026-10-20", "2026-10-20"), null);
  assert.equal(checkStart("2026-10-21", "2026-10-20"), "after_due");
  assert.equal(checkStart("2026-10-15", ""), "needs_due");
  assert.equal(checkStart("2026-10-15", null), "needs_due");
});

test("a one-day span keeps no start date", () => {
  assert.deepEqual(spanFields({ start: "2026-10-15", end: "2026-10-15" }), { startDate: null, dueDate: "2026-10-15" });
  assert.deepEqual(spanFields({ start: "2026-10-14", end: "2026-10-15" }), { startDate: "2026-10-14", dueDate: "2026-10-15" });
});

test("moving a task to another day keeps its span's length, and sends startDate only when it has one", () => {
  assert.deepEqual(shiftTo(task("a", "2026-10-20", "2026-10-15"), "2026-10-25"), { startDate: "2026-10-20", dueDate: "2026-10-25" });
  assert.deepEqual(shiftTo(task("a", "2026-10-20", "2026-10-15"), "2026-10-18"), { startDate: "2026-10-13", dueDate: "2026-10-18" });
  assert.deepEqual(shiftTo(task("b", "2026-10-20"), "2026-10-25"), { dueDate: "2026-10-25" });
  assert.equal("startDate" in shiftTo({ id: "c", dueDate: "2026-10-20" }, "2026-10-21"), false);
});

test("tasks by every day they occupy, clipped to the range", () => {
  const tasks = [task("trip", "2026-10-12", "2026-10-09"), task("one", "2026-10-10"), task("sub", "2026-10-10", null, { parentId: "x" }), task("none", null)];
  const byDay = tasksByOccupiedDay(tasks, "2026-10-10", "2026-10-16");
  assert.deepEqual(Object.keys(byDay).sort(), ["2026-10-10", "2026-10-11", "2026-10-12"]);
  assert.deepEqual(byDay["2026-10-10"].map((t) => t.id).sort(), ["one", "trip"]);
  assert.deepEqual(byDay["2026-10-12"].map((t) => t.id), ["trip"]);
  assert.equal(byDay["2026-10-09"], undefined);
});

test("single-day tasks by day leave out the spanning ones", () => {
  const byDay = singleDayByDay([task("trip", "2026-10-12", "2026-10-09"), task("one", "2026-10-10"), task("same", "2026-10-10", "2026-10-10")]);
  assert.deepEqual(byDay, { "2026-10-10": [byDay["2026-10-10"][0], byDay["2026-10-10"][1]] });
  assert.deepEqual(byDay["2026-10-10"].map((t) => t.id).sort(), ["one", "same"]);
});

const week = ["2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10"];

test("bars across a week: columns from the week's first day, lanes first-fit", () => {
  const { bars, lanes, hidden } = rowBars(week, [
    task("trip", "2026-10-12", "2026-10-09"), // continues into next week
    task("prep", "2026-10-06", "2026-10-02"), // started last week
    task("talk", "2026-10-08", "2026-10-07"),
    task("one", "2026-10-07"), // single day: no bar
  ]);
  const by = Object.fromEntries(bars.map((b) => [b.task.id, b]));
  assert.equal(bars.length, 3);
  assert.deepEqual(
    { column: by.prep.column, length: by.prep.length, lane: by.prep.lane, before: by.prep.continuesBefore, after: by.prep.continuesAfter },
    { column: 0, length: 3, lane: 0, before: true, after: false },
  );
  // «talk» starts after «prep» ends, so it shares lane 0.
  assert.deepEqual({ column: by.talk.column, length: by.talk.length, lane: by.talk.lane }, { column: 3, length: 2, lane: 0 });
  assert.deepEqual({ column: by.trip.column, length: by.trip.length, lane: by.trip.lane, after: by.trip.continuesAfter }, { column: 5, length: 2, lane: 0, after: true });
  assert.equal(lanes, 1);
  assert.deepEqual(hidden, [0, 0, 0, 0, 0, 0, 0]);
});

test("overlapping bars take new lanes; past maxLanes they are counted per column", () => {
  const tasks = [task("a", "2026-10-10", "2026-10-04"), task("b", "2026-10-06", "2026-10-05"), task("c", "2026-10-07", "2026-10-05"), task("d", "2026-10-08", "2026-10-06")];
  const all = rowBars(week, tasks);
  assert.deepEqual(Object.fromEntries(all.bars.map((b) => [b.task.id, b.lane])), { a: 0, c: 1, b: 2, d: 3 });
  const capped = rowBars(week, tasks, { maxLanes: 2 });
  assert.equal(capped.lanes, 2);
  assert.deepEqual(capped.bars.map((b) => b.task.id), ["a", "c"]);
  // b covers columns 1–2, d covers 2–4.
  assert.deepEqual(capped.hidden, [0, 1, 2, 1, 1, 0, 0]);
});

test("a span in words, both calendars, from and to", () => {
  const text = spanText({ start: "2026-10-13", end: "2026-10-16" }, { primary: "gregorian", today: "2026-10-15" });
  assert.match(text, /^من ١٣ أكتوبر، .+ إلى ١٦ أكتوبر، .+$/);
  assert.ok(!text.includes("·"));
  assert.equal(spanText({ start: "2026-10-16", end: "2026-10-16" }, { primary: "gregorian", today: "2026-10-15" }).startsWith("١٦ أكتوبر، "), true);
  assert.equal(spanText(null), "بلا تاريخ");
});
