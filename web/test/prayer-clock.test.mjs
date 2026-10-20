import assert from "node:assert/strict";
import { test } from "node:test";
import { clockIn, clockState, prayerInstant, timerText } from "../public/app/lib/prayer-clock.js";

const at = (hhmm) => Date.UTC(2026, 9, 20, ...hhmm.split(":").map(Number)) - 3 * 3600_000; // Riyadh, UTC+3
const day = {
  date: "2026-10-20",
  times: {
    fajr: { time: "04:38", at: at("04:38") },
    sunrise: { time: "05:56", at: at("05:56") },
    dhuhr: { time: "11:45", at: at("11:45") },
    asr: { time: "15:06", at: at("15:06") },
    maghrib: { time: "17:34", at: at("17:34") },
    isha: { time: "19:04", at: at("19:04") },
  },
};

test("counts down to the next adhan, and up for half an hour after one", () => {
  assert.deepEqual(clockState([day], at("13:00")), { kind: "until", prayer: "asr", at: at("15:06") });
  assert.deepEqual(clockState([day], at("15:20")), { kind: "since", prayer: "asr", at: at("15:06") });
  assert.deepEqual(clockState([day], at("15:40")), { kind: "until", prayer: "maghrib", at: at("17:34") });
  // Sunrise is no adhan.
  assert.equal(clockState([day], at("05:30")).prayer, "dhuhr");
  assert.equal(clockState([day], at("23:00")), null);
});

test("timers read as the app's", () => {
  assert.equal(timerText(((1 * 60 + 12) * 60 + 5) * 1000), "١:١٢:٠٥");
  assert.equal(timerText((12 * 60 + 3) * 1000), "١٢:٠٣");
  assert.equal(timerText(4000), "٠:٠٤");
});

test("a prayer-anchored task's time on its day", () => {
  assert.equal(prayerInstant([day], "2026-10-20", "asr", -10), at("14:56"));
  assert.equal(clockIn(prayerInstant([day], "2026-10-20", "maghrib", 20), "Asia/Riyadh"), "17:54");
  assert.equal(prayerInstant([day], "2026-10-21", "asr", 0), null);
});
