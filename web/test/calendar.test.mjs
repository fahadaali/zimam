import assert from "node:assert/strict";
import { test } from "node:test";
import {
  addMonths,
  calendarParts,
  dayDots,
  dayTitles,
  keyMove,
  leadingPadding,
  minuteOfDay,
  monthDays,
  monthLength,
  monthTitle,
  orderDay,
  rangeTitle,
  startOfMonth,
  weekDays,
  weekdayHeaders,
} from "../public/app/lib/calendar.js";

test("reads a day in both calendars (Umm al-Qura for Hijri)", () => {
  // 1 November 2026 is 21 Jumada al-Ula 1448.
  assert.deepEqual(calendarParts("2026-11-01", "hijri"), { year: 1448, month: 5, day: 21 });
  assert.deepEqual(calendarParts("2026-11-01", "gregorian"), { year: 2026, month: 11, day: 1 });
});

test("Hijri months have 29 or 30 days, by Umm al-Qura", () => {
  // Ramadan 1447 begins 18 February 2026 and has 30 days; Shawwal 1447 begins 20 March and has 29.
  assert.equal(startOfMonth("2026-03-01", "hijri"), "2026-02-18");
  assert.equal(monthLength("2026-03-01", "hijri"), 30);
  assert.equal(startOfMonth("2026-04-01", "hijri"), "2026-03-20");
  assert.equal(monthLength("2026-04-01", "hijri"), 29);
  // Muharram 1448 (from 16 June 2026) has 29 days.
  assert.equal(monthLength("2026-06-16", "hijri"), 29);
  for (const iso of ["2026-01-10", "2026-05-05", "2026-08-20", "2026-10-15", "2027-02-01"]) {
    assert.ok([29, 30].includes(monthLength(iso, "hijri")), iso);
  }
});

test("Gregorian months have 28 to 31 days", () => {
  assert.equal(monthLength("2026-02-10", "gregorian"), 28);
  assert.equal(monthLength("2028-02-10", "gregorian"), 29);
  assert.equal(monthLength("2026-04-10", "gregorian"), 30);
  assert.equal(monthLength("2026-10-10", "gregorian"), 31);
});

test("a Gregorian month grid: whole weeks, padded, starting on the chosen weekday", () => {
  // October 2026 starts on a Thursday.
  const sunday = monthDays("2026-10-15", { kind: "gregorian", weekStart: 0 });
  assert.equal(sunday.length % 7, 0);
  assert.equal(sunday.length, 35);
  assert.equal(sunday[0].day, "2026-09-27");
  assert.equal(sunday[4].day, "2026-10-01");
  assert.equal(sunday[4].inPeriod, true);
  assert.equal(sunday[3].inPeriod, false);
  assert.equal(sunday.filter((d) => d.inPeriod).length, 31);
  assert.equal(sunday.at(-1).day, "2026-10-31");
  // Each cell carries the Hijri day too: 1 October 2026 is 20 Rabi al-Akhir 1448.
  assert.equal(sunday[4].primaryDay, 1);
  assert.equal(sunday[4].secondaryDay, 20);

  const saturday = monthDays("2026-10-15", { kind: "gregorian", weekStart: 6 });
  assert.equal(leadingPadding("2026-10-15", { kind: "gregorian", weekStart: 6 }), 5);
  assert.equal(saturday[5].day, "2026-10-01");
});

test("a Hijri month grid follows the Hijri month, with Gregorian days beside it", () => {
  // Jumada al-Ula 1448: 12 October to 10 November 2026 (30 days), starting on a Monday.
  const days = monthDays("2026-10-15", { kind: "hijri", weekStart: 0 });
  const inMonth = days.filter((d) => d.inPeriod);
  assert.equal(inMonth.length, 30);
  assert.equal(inMonth[0].day, "2026-10-12");
  assert.equal(inMonth[0].primaryDay, 1);
  assert.equal(inMonth[0].secondaryDay, 12);
  assert.equal(inMonth.at(-1).day, "2026-11-10");
  assert.equal(days[0].day, "2026-10-11");
  assert.equal(days.length % 7, 0);

  // A 29-day month: Shawwal 1447 (20 March to 17 April 2026).
  const shawwal = monthDays("2026-04-01", { kind: "hijri", weekStart: 0 }).filter((d) => d.inPeriod);
  assert.equal(shawwal.length, 29);
  assert.equal(shawwal[0].day, "2026-03-20");
  assert.equal(shawwal.at(-1).day, "2026-04-17");
});

test("a week starts on the chosen weekday", () => {
  const week = weekDays("2026-10-15", { kind: "hijri", weekStart: 0 });
  assert.deepEqual(week.map((d) => d.day), ["2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"]);
  assert.equal(week[1].primaryDay, 1);
  assert.equal(weekDays("2026-10-15", { weekStart: 6 })[0].day, "2026-10-10");
});

test("adding months keeps the day, or the last day of a shorter month", () => {
  assert.equal(addMonths("2026-01-31", 1, "gregorian"), "2026-02-28");
  assert.equal(addMonths("2026-10-15", -1, "gregorian"), "2026-09-15");
  assert.equal(addMonths("2026-10-15", 12, "gregorian"), "2027-10-15");
  // 30 Ramadan 1447 (19 March 2026) + 1 month: Shawwal has 29 days, so its 29th (17 April).
  assert.equal(addMonths("2026-03-19", 1, "hijri"), "2026-04-17");
  // 4 Jumada al-Ula 1448 → 4 Jumada al-Akhirah.
  const next = addMonths("2026-10-15", 1, "hijri");
  assert.deepEqual(calendarParts(next, "hijri"), { year: 1448, month: 6, day: 4 });
  assert.deepEqual(calendarParts(addMonths("2026-10-15", -5, "hijri"), "hijri"), { year: 1447, month: 12, day: 4 });
});

test("titles name both calendars with the Arabic comma, never a middle dot", () => {
  assert.equal(monthTitle("2026-10-15", "hijri"), "جمادى الأولى ١٤٤٨هـ، أكتوبر – نوفمبر ٢٠٢٦م");
  assert.equal(monthTitle("2026-10-15", "gregorian"), "أكتوبر ٢٠٢٦م، ربيع الآخر – جمادى الأولى ١٤٤٨هـ");
  assert.equal(monthTitle("2026-12-20", "hijri"), "رجب ١٤٤٨هـ، ديسمبر ٢٠٢٦م – يناير ٢٠٢٧م");
  assert.equal(rangeTitle("2026-10-18", "2026-10-24", "hijri"), "٧ – ١٣ جمادى الأولى ١٤٤٨هـ، ١٨ – ٢٤ أكتوبر ٢٠٢٦م");
  assert.ok(!monthTitle("2026-10-15", "hijri").includes("·"));
});

test("weekday headers follow the week start", () => {
  const sunday = weekdayHeaders(0);
  assert.equal(sunday.length, 7);
  assert.equal(sunday[0].long, "الأحد");
  assert.equal(weekdayHeaders(6)[0].long, "السبت");
  assert.equal(weekdayHeaders(1)[6].long, "الأحد");
});

test("keyboard moves: right goes back a day in Arabic", () => {
  const opts = { kind: "gregorian", weekStart: 0 };
  assert.equal(keyMove("2026-10-15", "ArrowRight", opts), "2026-10-14");
  assert.equal(keyMove("2026-10-15", "ArrowLeft", opts), "2026-10-16");
  assert.equal(keyMove("2026-10-15", "ArrowRight", { ...opts, rtl: false }), "2026-10-16");
  assert.equal(keyMove("2026-10-15", "ArrowDown", opts), "2026-10-22");
  assert.equal(keyMove("2026-10-15", "Home", opts), "2026-10-11");
  assert.equal(keyMove("2026-10-15", "End", opts), "2026-10-17");
  assert.equal(keyMove("2026-10-15", "PageDown", opts), "2026-11-15");
  assert.equal(keyMove("2026-10-15", "x", opts), null);
});

test("a day's tasks: untimed first, then by clock or prayer time", () => {
  const tasks = [
    { id: "isha", duePrayer: "isha", duePrayerOffset: 0, dueDate: "2026-10-15", sortOrder: 0 },
    { id: "nine", dueTime: "09:00", dueDate: "2026-10-15", sortOrder: 0 },
    { id: "free", dueDate: "2026-10-15", sortOrder: 2 },
    { id: "free-first", dueDate: "2026-10-15", sortOrder: 1 },
    { id: "before-dhuhr", duePrayer: "dhuhr", duePrayerOffset: -30, dueDate: "2026-10-15", sortOrder: 0 },
  ];
  assert.equal(minuteOfDay(tasks[1]), 540);
  assert.equal(minuteOfDay(tasks[4]), 690);
  assert.deepEqual(orderDay(tasks).map((t) => t.id), ["free-first", "free", "nine", "before-dhuhr", "isha"]);
});

test("a wide month cell shows two titles, prayer ones in sand, then the rest counted", () => {
  const tasks = [
    { id: "a", title: "صلة الرحم", duePrayer: "maghrib" },
    { id: "b", title: "مراجعة العقد" },
    { id: "c", title: "شراء الخبز" },
    { id: "d", title: "الاتصال بأحمد" },
  ];
  assert.deepEqual(dayTitles(tasks), {
    titles: [
      { id: "a", title: "صلة الرحم", prayer: true },
      { id: "b", title: "مراجعة العقد", prayer: false },
    ],
    more: 2,
  });
  assert.deepEqual(dayTitles(tasks.slice(1, 2)), { titles: [{ id: "b", title: "مراجعة العقد", prayer: false }], more: 0 });
  assert.deepEqual(dayTitles([]), { titles: [], more: 0 });
});

test("a narrow month cell shows up to three dots, then the count instead", () => {
  const task = (prayer) => ({ title: "x", duePrayer: prayer ? "asr" : null });
  assert.deepEqual(dayDots([task(true), task(false)]), { dots: [{ prayer: true }, { prayer: false }], count: null });
  assert.deepEqual(dayDots([task(), task(), task()]).dots.length, 3);
  assert.deepEqual(dayDots([task(), task(), task(), task()]), { dots: [], count: 4 });
  assert.deepEqual(dayDots(undefined), { dots: [], count: null });
});
