import assert from "node:assert/strict";
import { test } from "node:test";
import { chooseFrequency, formatRule, parseRule, ruleChoice, ruleText, toggleWeekday, weekdayOf } from "../public/app/lib/recurrence.js";

test("reads and writes the rules the app does", () => {
  assert.deepEqual(parseRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=TH,MO"), { frequency: "WEEKLY", interval: 2, weekdays: ["MO", "TH"], count: null, until: null });
  assert.deepEqual(parseRule("RRULE:FREQ=DAILY;COUNT=3;UNTIL=20261231"), { frequency: "DAILY", interval: 1, weekdays: [], count: 3, until: "2026-12-31" });
  assert.equal(parseRule("FREQ=HOURLY"), null);
  assert.equal(parseRule("FREQ=WEEKLY;BYDAY=1MO"), null);
  assert.equal(parseRule(""), null);
  assert.equal(formatRule({ frequency: "WEEKLY", interval: 2, weekdays: ["TH", "MO"] }), "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH");
  assert.equal(formatRule({ frequency: "MONTHLY", until: "2027-01-31" }), "FREQ=MONTHLY;UNTIL=20270131");
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
