import assert from "node:assert/strict";
import { test } from "node:test";
import { chooseFrequency, formatRule, movedRule, nextOccurrence, parseRule, ruleChoice, ruleText, toggleWeekday, weekdayOf } from "../public/app/lib/recurrence.js";

test("reads and writes the rules the app does", () => {
  assert.deepEqual(parseRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=TH,MO"), {
    frequency: "WEEKLY", interval: 2, weekdays: ["MO", "TH"], count: null, until: null, monthDay: null, month: null,
  });
  assert.deepEqual(parseRule("RRULE:FREQ=DAILY;COUNT=3;UNTIL=20261231"), {
    frequency: "DAILY", interval: 1, weekdays: [], count: 3, until: "2026-12-31", monthDay: null, month: null,
  });
  assert.equal(parseRule("FREQ=HOURLY"), null);
  assert.equal(parseRule("FREQ=WEEKLY;BYDAY=1MO"), null);
  assert.equal(parseRule(""), null);
  assert.equal(formatRule({ frequency: "WEEKLY", interval: 2, weekdays: ["TH", "MO"] }), "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH");
  assert.equal(formatRule({ frequency: "MONTHLY", until: "2027-01-31" }), "FREQ=MONTHLY;UNTIL=20270131");
  assert.equal(formatRule(parseRule("FREQ=MONTHLY;WKST=SU")), "FREQ=MONTHLY");
  assert.equal(formatRule(parseRule("FREQ=MONTHLY;BYMONTHDAY=31")), "FREQ=MONTHLY;BYMONTHDAY=31");
  assert.equal(formatRule(parseRule("FREQ=YEARLY;BYMONTHDAY=29;BYMONTH=2;COUNT=3")), "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;COUNT=3");
  assert.equal(parseRule("FREQ=YEARLY;BYMONTH=3").month, 3);
  // Every day on some weekdays is weekly on them: the Saudi working week.
  const workdays = parseRule("FREQ=DAILY;BYDAY=SU,MO,TU,WE,TH");
  assert.equal(workdays.frequency, "WEEKLY");
  assert.equal(formatRule(workdays), "FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH");
  assert.equal(nextOccurrence("FREQ=DAILY;BYDAY=SU,MO,TU,WE,TH", "2026-10-15").day, "2026-10-18");
});

// Rules with days Zimam cannot follow are not read as a plainer rule that would put the next
// occurrence on another day: they read as «تكرار مخصص», and completing adds none.
test("rejects parts that pick other days, as Recurrence.swift does", () => {
  for (const rule of [
    "FREQ=MONTHLY;BYDAY=FR;BYSETPOS=1",
    "FREQ=MONTHLY;BYSETPOS=-1;BYDAY=FR",
    "FREQ=MONTHLY;BYDAY=MO",
    "FREQ=WEEKLY;BYDAY=1MO",
    "FREQ=MONTHLY;BYMONTHDAY=1,15",
    "FREQ=MONTHLY;BYMONTHDAY=-1",
    "FREQ=YEARLY;BYMONTH=1,7",
    "FREQ=YEARLY;BYMONTHDAY=15",
    "FREQ=WEEKLY;BYMONTHDAY=3",
    "FREQ=MONTHLY;BYMONTH=3",
    "FREQ=DAILY;INTERVAL=2;BYDAY=MO",
    "FREQ=DAILY;BYHOUR=9",
    "FREQ=YEARLY;BYYEARDAY=100",
  ]) {
    assert.equal(parseRule(rule), null, rule);
    assert.equal(ruleChoice(rule), "custom", rule);
    assert.equal(nextOccurrence(rule, "2026-10-20"), null, rule);
  }
});

test("the picker's choice and its changes", () => {
  assert.equal(ruleChoice(null), "off");
  assert.equal(ruleChoice("FREQ=MONTHLY"), "MONTHLY");
  assert.equal(ruleChoice("FREQ=SECONDLY"), "custom");
  // 2026-10-15 is a Thursday: a weekly rule starts on it.
  assert.equal(chooseFrequency(null, "WEEKLY", "2026-10-15"), "FREQ=WEEKLY;BYDAY=TH");
  assert.equal(chooseFrequency("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO", "WEEKLY", "2026-10-15"), "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO");
  assert.equal(chooseFrequency("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO", "DAILY", null), "FREQ=DAILY");
  assert.equal(chooseFrequency("FREQ=DAILY", "off", null), null);
  // The same frequency again keeps the series' day of the month.
  assert.equal(chooseFrequency("FREQ=MONTHLY;BYMONTHDAY=31", "MONTHLY", "2027-02-28"), "FREQ=MONTHLY;BYMONTHDAY=31");
  assert.equal(chooseFrequency("FREQ=MONTHLY;BYMONTHDAY=31", "YEARLY", "2027-02-28"), "FREQ=YEARLY");
  assert.equal(weekdayOf("2026-10-20"), "TU");
});

test("weekdays toggle, but the last one stays", () => {
  assert.equal(toggleWeekday("FREQ=WEEKLY;BYDAY=TH", "SU"), "FREQ=WEEKLY;BYDAY=SU,TH");
  assert.equal(toggleWeekday("FREQ=WEEKLY;BYDAY=SU,TH", "SU"), "FREQ=WEEKLY;BYDAY=TH");
  assert.equal(toggleWeekday("FREQ=WEEKLY;BYDAY=TH", "TH"), "FREQ=WEEKLY;BYDAY=TH");
});

test("reads in Arabic as the app says it", () => {
  assert.equal(ruleText("FREQ=DAILY"), "كل يوم");
  assert.equal(ruleText("FREQ=DAILY;INTERVAL=3"), "كل ٣ أيام");
  assert.equal(ruleText("FREQ=DAILY;INTERVAL=11"), "كل ١١ يوماً");
  assert.equal(ruleText("FREQ=WEEKLY;BYDAY=TH"), "كل أسبوع يوم الخميس");
  assert.equal(ruleText("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH"), "كل أسبوعين يومي الإثنين والخميس");
  assert.equal(ruleText("FREQ=WEEKLY;BYDAY=SU,MO,TU"), "كل أسبوع أيام الأحد والإثنين والثلاثاء");
  assert.equal(ruleText("FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH,FR,SA"), "كل يوم");
  assert.equal(ruleText("FREQ=MONTHLY"), "كل شهر");
  assert.equal(ruleText("FREQ=YEARLY;INTERVAL=2"), "كل سنتين");
  assert.equal(ruleText("nonsense"), null);
});

test("the next occurrence, as Recurrence.swift finds it", async () => {
  const { nextOccurrence } = await import("../public/app/lib/recurrence.js");
  assert.deepEqual(nextOccurrence("FREQ=DAILY", "2026-10-20"), { day: "2026-10-21", recurrence: "FREQ=DAILY" });
  assert.deepEqual(nextOccurrence("FREQ=DAILY;INTERVAL=3", "2026-10-20"), { day: "2026-10-23", recurrence: "FREQ=DAILY;INTERVAL=3" });
  // Tuesday the 20th, weekly on Monday and Thursday: Thursday the 22nd, then Monday the 26th.
  assert.equal(nextOccurrence("FREQ=WEEKLY;BYDAY=MO,TH", "2026-10-20").day, "2026-10-22");
  assert.equal(nextOccurrence("FREQ=WEEKLY;BYDAY=MO,TH", "2026-10-22").day, "2026-10-26");
  // Every two weeks on Thursday, from Thursday the 22nd: the 5th of November.
  assert.equal(nextOccurrence("FREQ=WEEKLY;INTERVAL=2;BYDAY=TH", "2026-10-22").day, "2026-11-05");
  assert.equal(nextOccurrence("FREQ=WEEKLY", "2026-10-20").day, "2026-10-27");
  assert.equal(nextOccurrence("FREQ=MONTHLY", "2027-01-31").day, "2027-02-28");
  assert.equal(nextOccurrence("FREQ=YEARLY", "2028-02-29").day, "2029-02-28");
  // COUNT counts the occurrences left, this one included.
  assert.deepEqual(nextOccurrence("FREQ=DAILY;COUNT=3", "2026-10-20"), { day: "2026-10-21", recurrence: "FREQ=DAILY;COUNT=2" });
  assert.equal(nextOccurrence("FREQ=DAILY;COUNT=1", "2026-10-20"), null);
  assert.equal(nextOccurrence("FREQ=DAILY;UNTIL=20261020", "2026-10-20"), null);
  // Completing an overdue task schedules from today, not in the past.
  assert.equal(nextOccurrence("FREQ=DAILY", "2026-10-10", "2026-10-20").day, "2026-10-20");
  assert.equal(nextOccurrence("nonsense", "2026-10-20"), null);
});

// The series' day survives a short month: the 31st, then 28 February, then the 31st again.
test("a monthly series keeps its day", () => {
  const february = nextOccurrence("FREQ=MONTHLY", "2026-01-31");
  assert.deepEqual(february, { day: "2026-02-28", recurrence: "FREQ=MONTHLY;BYMONTHDAY=31" });
  const march = nextOccurrence(february.recurrence, february.day);
  assert.deepEqual(march, { day: "2026-03-31", recurrence: "FREQ=MONTHLY" });
  assert.equal(nextOccurrence(march.recurrence, march.day).day, "2026-04-30");
  // Completed late: the months on the way do not move it either.
  assert.equal(nextOccurrence("FREQ=MONTHLY", "2026-01-31", "2026-04-15").day, "2026-04-30");
});

test("a yearly series on the leap day comes back to it", () => {
  let day = "2028-02-29";
  let rule = "FREQ=YEARLY";
  const days = [];
  for (let i = 0; i < 4; i++) {
    const next = nextOccurrence(rule, day);
    days.push(next.day);
    day = next.day;
    rule = next.recurrence;
  }
  assert.deepEqual(days, ["2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"]);
  assert.equal(rule, "FREQ=YEARLY");
});

// A month day other than the task's own: the next one is on it, this month if still to come.
test("a month day picks the day", () => {
  assert.deepEqual(nextOccurrence("FREQ=MONTHLY;BYMONTHDAY=1", "2026-10-24"), { day: "2026-11-01", recurrence: "FREQ=MONTHLY" });
  assert.equal(nextOccurrence("FREQ=MONTHLY;BYMONTHDAY=20", "2026-10-15").day, "2026-10-20");
  assert.equal(nextOccurrence("FREQ=YEARLY;BYMONTH=3", "2026-10-24").day, "2027-03-24");
});

// 28 February carrying the series' 31st, moved to the 10th: the series follows the move, as a plain
// rule's does, so completing it adds 10 March rather than a second February occurrence.
test("a moved occurrence takes the series with it", () => {
  assert.equal(nextOccurrence("FREQ=MONTHLY;BYMONTHDAY=31", "2026-02-10").day, "2026-02-28");
  const moved = movedRule("FREQ=MONTHLY;BYMONTHDAY=31", "2026-02-28");
  assert.equal(moved, "FREQ=MONTHLY");
  assert.equal(nextOccurrence(moved, "2026-02-10").day, "2026-03-10");
  assert.equal(movedRule("FREQ=MONTHLY;BYMONTHDAY=31", "2026-03-31"), "FREQ=MONTHLY");
  // A day the rule picks other than the task's own stays.
  assert.equal(movedRule("FREQ=MONTHLY;BYMONTHDAY=20", "2026-10-15"), "FREQ=MONTHLY;BYMONTHDAY=20");
  assert.equal(movedRule("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29", "2029-02-28"), "FREQ=YEARLY");
  assert.equal(movedRule("FREQ=YEARLY;BYMONTH=3", "2026-10-24"), "FREQ=YEARLY;BYMONTH=3");
  assert.equal(movedRule("FREQ=WEEKLY;BYDAY=MO", "2026-10-19"), "FREQ=WEEKLY;BYDAY=MO");
});
