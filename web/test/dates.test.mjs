import assert from "node:assert/strict";
import { test } from "node:test";
import {
  addDays,
  dateLabel,
  dayDiff,
  dayHeading,
  dualDate,
  dueChip,
  formatGregorian,
  formatHijri,
  isIsoDate,
  localIsoDate,
  parseIsoDate,
  relativeDay,
  weekdayName,
} from "../public/app/lib/dates.js";

const TODAY = "2026-10-13"; // Tuesday, 2 Jumada al-Ula 1448

test("Hijri is Umm al-Qura with Arabic-Indic digits", () => {
  assert.equal(formatHijri("2026-10-13"), "٢ جمادى الأولى");
  assert.equal(formatHijri("2026-10-13", { year: true }), "٢ جمادى الأولى ١٤٤٨ هـ");
});

test("Gregorian uses Arabic month names and Arabic-Indic digits", () => {
  assert.equal(formatGregorian("2026-10-13"), "١٣ أكتوبر");
  assert.equal(formatGregorian("2027-01-05", { year: true }), "٥ يناير ٢٠٢٧");
});

test("dual date: Hijri first by default, separated by the Arabic comma", () => {
  assert.equal(dualDate("2026-10-13"), "٢ جمادى الأولى، ١٣ أكتوبر");
  assert.equal(dualDate("2026-10-13", { primary: "gregorian" }), "١٣ أكتوبر، ٢ جمادى الأولى");
  assert.ok(!dualDate("2026-10-13").includes("·"), "never the middle dot");
});

test("dual date adds years only outside the current Gregorian year", () => {
  assert.equal(dualDate("2026-12-01", { today: TODAY }), dualDate("2026-12-01"));
  assert.match(dualDate("2027-01-05", { today: TODAY }), /١٤٤٨ هـ، ٥ يناير ٢٠٢٧$/);
});

test("near days read as one word", () => {
  assert.equal(relativeDay("2026-10-13", TODAY), "اليوم");
  assert.equal(relativeDay("2026-10-14", TODAY), "غداً");
  assert.equal(relativeDay("2026-10-15", TODAY), "الخميس");
  assert.equal(relativeDay("2026-10-19", TODAY), "الاثنين");
  assert.equal(relativeDay("2026-10-20", TODAY), null);
  assert.equal(relativeDay("2026-10-12", TODAY), null);
});

test("date label: word for near days, both calendars otherwise", () => {
  assert.equal(dateLabel("2026-10-14", { today: TODAY }), "غداً");
  assert.equal(dateLabel("2026-10-30", { today: TODAY }), "١٩ جمادى الأولى، ٣٠ أكتوبر");
  assert.equal(dateLabel("2026-10-30", { today: TODAY, primary: "gregorian" }), "٣٠ أكتوبر، ١٩ جمادى الأولى");
});

test("due chip: overdue shows the full date in the overdue tone", () => {
  assert.deepEqual(dueChip("2026-10-11", { today: TODAY }), {
    text: "٣٠ ربيع الآخر، ١١ أكتوبر",
    full: "٣٠ ربيع الآخر، ١١ أكتوبر",
    tone: "overdue",
  });
  assert.equal(dueChip("2026-10-13", { today: TODAY }).text, "اليوم");
  assert.equal(dueChip("2026-10-13", { today: TODAY }).tone, "default");
});

test("day headings pair the word with the dual date", () => {
  assert.deepEqual(dayHeading("2026-10-14", { today: TODAY }), { title: "غداً", subtitle: "الأربعاء، ٣ جمادى الأولى، ١٤ أكتوبر" });
  assert.deepEqual(dayHeading("2026-10-16", { today: TODAY }), { title: "الجمعة", subtitle: "٥ جمادى الأولى، ١٦ أكتوبر" });
  assert.deepEqual(dayHeading("2026-11-02", { today: TODAY }), { title: "٢٢ جمادى الأولى، ٢ نوفمبر", subtitle: "الاثنين" });
});

test("calendar arithmetic is by local day, not by time zone", () => {
  assert.equal(addDays("2026-10-13", 1), "2026-10-14");
  assert.equal(addDays("2026-12-31", 1), "2027-01-01");
  assert.equal(addDays("2026-03-01", -1), "2026-02-28");
  assert.equal(dayDiff("2026-10-13", "2026-10-20"), 7);
  assert.equal(dayDiff("2026-10-13", "2026-10-12"), -1);
  assert.equal(weekdayName("2026-10-13"), "الثلاثاء");
  assert.equal(localIsoDate(new Date(2026, 9, 13, 23, 59)), "2026-10-13");
});

test("only real ISO dates parse", () => {
  assert.equal(parseIsoDate("2026-10-13").toISOString(), "2026-10-13T12:00:00.000Z");
  assert.equal(isIsoDate("2026-02-30"), false);
  assert.equal(isIsoDate("13/10/2026"), false);
  assert.equal(isIsoDate(""), false);
  assert.throws(() => parseIsoDate(null), RangeError);
});

test("a task's clock time in Arabic digits", async () => {
  const { timeLabel } = await import("../public/app/lib/dates.js");
  assert.match(timeLabel("15:00"), /^٣:٠٠/);
  assert.match(timeLabel("09:05"), /^٩:٠٥/);
  assert.equal(timeLabel(null), null);
  assert.equal(timeLabel("9:5"), null);
});
