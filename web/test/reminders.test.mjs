import assert from "node:assert/strict";
import { test } from "node:test";
import { localToIso, presetsFor, relativeText, reminderLabel, sortReminders } from "../public/app/lib/reminders.js";

test("relative reminders read as the app's", () => {
  assert.equal(relativeText(0), "عند الموعد");
  assert.equal(relativeText(-15), "قبل ١٥ د");
  assert.equal(relativeText(-60), "قبل ساعة");
  assert.equal(relativeText(-120), "قبل ساعتين");
  assert.equal(relativeText(-180), "قبل ٣ س");
  assert.equal(relativeText(-1440), "قبل يوم");
  assert.equal(relativeText(-2880), "قبل يومين");
  assert.equal(relativeText(-4320), "قبل ٣ أيام");
});

test("presets leave out those added, and all-day tasks get the morning and the day before", () => {
  const timed = { dueDate: "2026-10-20", dueTime: "15:00" };
  assert.deepEqual(presetsFor(timed, [{ kind: "relative", offsetMinutes: -15 }]), [0, -5, -30, -60, -1440]);
  assert.deepEqual(presetsFor({ dueDate: "2026-10-20" }, []), [0, -1440]);
  assert.deepEqual(presetsFor({ duePrayer: "asr" }, []), [0, -5, -15, -30, -60, -1440]);
});

test("rows: relative ones first, soonest first", () => {
  const sorted = sortReminders([
    { id: "a", kind: "time" },
    { id: "b", kind: "relative", offsetMinutes: 0 },
    { id: "c", kind: "relative", offsetMinutes: -60 },
    { id: "d", kind: "prayer" },
  ]);
  assert.deepEqual(sorted.map((r) => r.id), ["c", "b", "a", "d"]);
  assert.deepEqual(reminderLabel({ kind: "prayer", prayer: "asr", offsetMinutes: -10 }), { kind: "prayer", text: "قبل العصر بـ١٠ د" });
  assert.equal(reminderLabel({ kind: "location", location: { name: "البيت", trigger: "arrive" } }).text, "عند الوصول إلى البيت");
});

test("a local time with the viewer's offset", () => {
  assert.equal(localToIso("2026-10-20T15:30", 180), "2026-10-20T15:30:00+03:00");
  assert.equal(localToIso("2026-10-20T15:30", -270), "2026-10-20T15:30:00-04:30");
  assert.equal(localToIso("bad", 0), null);
});
