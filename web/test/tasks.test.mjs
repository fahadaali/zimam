import assert from "node:assert/strict";
import { test } from "node:test";
import { randomNonce, sha256Hex } from "../public/app/lib/nonce.js";
import { arabicNumber, parseDigits } from "../public/app/lib/numbers.js";
import { groupByDay, priorityKey, progressPercent, progressText, splitToday, taskCount } from "../public/app/lib/tasks.js";

const task = (id, dueDate, extra = {}) => ({ id, title: id, status: "todo", dueDate, ...extra });

test("project progress reads «٧ من ١٢»", () => {
  assert.equal(progressText(7, 12), "٧ من ١٢");
  assert.equal(progressPercent(7, 12), 58);
  assert.equal(progressPercent(0, 0), 0);
});

test("Arabic-Indic digits in and out", () => {
  assert.equal(arabicNumber(2026), "٢٠٢٦");
  assert.equal(parseDigits("٢٠"), 20);
  assert.equal(parseDigits("۱۵"), 15);
  assert.equal(parseDigits(" 45 "), 45);
  assert.ok(Number.isNaN(parseDigits("٢٠ د")));
});

test("task counts agree with the number", () => {
  assert.equal(taskCount(1), "مهمة واحدة");
  assert.equal(taskCount(2), "مهمتان");
  assert.equal(taskCount(5), "٥ مهام");
  assert.equal(taskCount(12), "١٢ مهمة");
});

test("upcoming tasks group by day in date order", () => {
  const groups = groupByDay([task("b", "2026-10-15"), task("a", "2026-10-14"), task("c", "2026-10-15"), task("x", null)]);
  assert.deepEqual(
    groups.map((g) => [g.date, g.tasks.map((t) => t.id)]),
    [
      ["2026-10-14", ["a"]],
      ["2026-10-15", ["b", "c"]],
    ],
  );
});

test("today splits overdue from due today", () => {
  const { overdue, due } = splitToday([task("old", "2026-10-01"), task("now", "2026-10-13")], "2026-10-13");
  assert.deepEqual(overdue.map((t) => t.id), ["old"]);
  assert.deepEqual(due.map((t) => t.id), ["now"]);
});

test("API priority maps to the row flag", () => {
  assert.equal(priorityKey(0), null);
  assert.equal(priorityKey(1), "low");
  assert.equal(priorityKey(3), "high");
});

test("nonce: random, URL-safe, hashed as the API expects", async () => {
  const a = randomNonce();
  assert.match(a, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(a, randomNonce());
  assert.equal(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});
