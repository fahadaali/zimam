import { describe, expect, it } from "vitest";
import { movedRule, nextOccurrence } from "../src/data/recurrence";

// The cases of web/test/recurrence.test.mjs, so the server adds what the apps add.
describe("Next occurrence", () => {
  it("finds the day Recurrence.swift finds", () => {
    expect(nextOccurrence("FREQ=DAILY", "2026-10-20")).toEqual({ day: "2026-10-21", recurrence: "FREQ=DAILY" });
    expect(nextOccurrence("FREQ=DAILY;INTERVAL=3", "2026-10-20")).toEqual({ day: "2026-10-23", recurrence: "FREQ=DAILY;INTERVAL=3" });
    // Tuesday the 20th, weekly on Monday and Thursday: Thursday the 22nd, then Monday the 26th.
    expect(nextOccurrence("FREQ=WEEKLY;BYDAY=MO,TH", "2026-10-20")?.day).toBe("2026-10-22");
    expect(nextOccurrence("FREQ=WEEKLY;BYDAY=MO,TH", "2026-10-22")?.day).toBe("2026-10-26");
    // Every two weeks on Thursday, from Thursday the 22nd: the 5th of November.
    expect(nextOccurrence("FREQ=WEEKLY;INTERVAL=2;BYDAY=TH", "2026-10-22")?.day).toBe("2026-11-05");
    expect(nextOccurrence("FREQ=WEEKLY", "2026-10-20")?.day).toBe("2026-10-27");
    expect(nextOccurrence("FREQ=MONTHLY", "2027-01-31")?.day).toBe("2027-02-28");
    expect(nextOccurrence("FREQ=YEARLY", "2028-02-29")?.day).toBe("2029-02-28");
  });

  it("counts down COUNT, stops at UNTIL, and skips days before today", () => {
    // COUNT counts the occurrences left, this one included.
    expect(nextOccurrence("FREQ=DAILY;COUNT=3", "2026-10-20")).toEqual({ day: "2026-10-21", recurrence: "FREQ=DAILY;COUNT=2" });
    expect(nextOccurrence("FREQ=DAILY;COUNT=1", "2026-10-20")).toBeNull();
    expect(nextOccurrence("FREQ=DAILY;UNTIL=20261020", "2026-10-20")).toBeNull();
    // Completing an overdue task schedules from today, not in the past.
    expect(nextOccurrence("FREQ=DAILY", "2026-10-10", "2026-10-20")?.day).toBe("2026-10-20");
    expect(nextOccurrence("RRULE:FREQ=WEEKLY;WKST=SU;BYDAY=th", "2026-10-20")).toEqual({ day: "2026-10-22", recurrence: "FREQ=WEEKLY;BYDAY=TH" });
    expect(nextOccurrence("nonsense", "2026-10-20")).toBeNull();
    expect(nextOccurrence("FREQ=WEEKLY;BYDAY=2MO", "2026-10-20")).toBeNull();
  });

  it("keeps a monthly or yearly series on its day across a short month", () => {
    const february = nextOccurrence("FREQ=MONTHLY", "2026-01-31");
    expect(february).toEqual({ day: "2026-02-28", recurrence: "FREQ=MONTHLY;BYMONTHDAY=31" });
    expect(nextOccurrence(february!.recurrence, february!.day)).toEqual({ day: "2026-03-31", recurrence: "FREQ=MONTHLY" });
    // Completed late: the months on the way do not move it either.
    expect(nextOccurrence("FREQ=MONTHLY", "2026-01-31", "2026-04-15")?.day).toBe("2026-04-30");
    let day = "2028-02-29";
    let rule = "FREQ=YEARLY";
    const days: string[] = [];
    for (let i = 0; i < 4; i++) {
      const next = nextOccurrence(rule, day)!;
      days.push(next.day);
      day = next.day;
      rule = next.recurrence;
    }
    expect(days).toEqual(["2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"]);
    expect(rule).toBe("FREQ=YEARLY");
  });

  it("follows BYMONTHDAY and BYMONTH, and daily on some weekdays as weekly", () => {
    expect(nextOccurrence("FREQ=MONTHLY;BYMONTHDAY=1", "2026-10-24")).toEqual({ day: "2026-11-01", recurrence: "FREQ=MONTHLY" });
    expect(nextOccurrence("FREQ=MONTHLY;BYMONTHDAY=20", "2026-10-15")?.day).toBe("2026-10-20");
    expect(nextOccurrence("FREQ=YEARLY;BYMONTH=3", "2026-10-24")?.day).toBe("2027-03-24");
    expect(nextOccurrence("FREQ=DAILY;BYDAY=SU,MO,TU,WE,TH", "2026-10-15")).toEqual({ day: "2026-10-18", recurrence: "FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH" });
  });

  it("follows no rule with parts that pick other days", () => {
    for (const rule of [
      "FREQ=MONTHLY;BYDAY=FR;BYSETPOS=1",
      "FREQ=MONTHLY;BYDAY=MO",
      "FREQ=MONTHLY;BYMONTHDAY=1,15",
      "FREQ=MONTHLY;BYMONTHDAY=-1",
      "FREQ=YEARLY;BYMONTH=1,7",
      "FREQ=YEARLY;BYMONTHDAY=15",
      "FREQ=MONTHLY;BYMONTH=3",
      "FREQ=DAILY;INTERVAL=2;BYDAY=MO",
      "FREQ=DAILY;BYHOUR=9",
      "FREQ=YEARLY;BYYEARDAY=100",
    ]) {
      expect(nextOccurrence(rule, "2026-10-20"), rule).toBeNull();
    }
  });

  it("lets a moved occurrence take the series with it", () => {
    expect(nextOccurrence("FREQ=MONTHLY;BYMONTHDAY=31", "2026-02-10")?.day).toBe("2026-02-28");
    expect(movedRule("FREQ=MONTHLY;BYMONTHDAY=31", "2026-02-28")).toBe("FREQ=MONTHLY");
    expect(nextOccurrence("FREQ=MONTHLY", "2026-02-10")?.day).toBe("2026-03-10");
    expect(movedRule("FREQ=MONTHLY;BYMONTHDAY=20", "2026-10-15")).toBe("FREQ=MONTHLY;BYMONTHDAY=20");
    expect(movedRule("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29", "2029-02-28")).toBe("FREQ=YEARLY");
  });
});
