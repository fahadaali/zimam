import assert from "node:assert/strict";
import { test } from "node:test";
import { randomNonce, sha256Hex } from "../public/app/lib/nonce.js";
import { arabicNumber } from "../public/app/lib/numbers.js";
import { groupByDay, priorityKey, progressText, taskCount } from "../public/app/lib/tasks.js";

const task = (id, dueDate, extra = {}) => ({ id, title: id, status: "todo", dueDate, ...extra });

test("project progress reads «٧ من ١٢»", () => {
  assert.equal(progressText(7, 12), "٧ من ١٢");
});

test("Arabic-Indic digits", () => {
  assert.equal(arabicNumber(2026), "٢٠٢٦");
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

test("today's list: due today or earlier, top-level, by date then time", async () => {
  const { todayList } = await import("../public/app/lib/tasks.js");
  const list = todayList(
    [
      { id: "b", dueDate: "2026-10-20", dueTime: "15:00" },
      { id: "a", dueDate: "2026-10-20", dueTime: null },
      { id: "c", dueDate: "2026-10-18" },
      { id: "d", dueDate: "2026-10-21" },
      { id: "e", dueDate: "2026-10-20", parentId: "a" },
      { id: "f", dueDate: "2026-10-20", dueTime: "09:30" },
    ],
    "2026-10-20",
  );
  assert.deepEqual(list.map((t) => t.id), ["c", "a", "f", "b"]);
});

test("today's list puts a prayer task among the clock times, at the prayer's usual time", async () => {
  const { todayList } = await import("../public/app/lib/tasks.js");
  const list = todayList(
    [
      { id: "asr", dueDate: "2026-10-20", duePrayer: "asr", duePrayerOffset: 0 },
      { id: "ten", dueDate: "2026-10-20", dueTime: "10:00" },
      { id: "late", dueDate: "2026-10-20", dueTime: "18:00" },
    ],
    "2026-10-20",
  );
  assert.deepEqual(list.map((t) => t.id), ["ten", "asr", "late"]);
});
