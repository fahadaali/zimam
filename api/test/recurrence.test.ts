import { describe, expect, it } from "vitest";
import { nextOccurrence } from "../src/data/recurrence";

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
});
