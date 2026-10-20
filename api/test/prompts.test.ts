import { describe, expect, it } from "vitest";
import { PARSE_SYSTEM } from "../src/ai/prompts";

// The device reads the same times when the assistant cannot (apple/ZimamKit SpokenTime.swift);
// these rules must stay in step with it.
describe("Parse prompt", () => {
  it("keeps the time rules the device's reader follows", () => {
    for (const rule of [
      "«قبل X» without a duration = -15",
      "«صلاة الجمعة» or «بعد الجمعة» = dhuhr on the next Friday",
      "«بين المغرب والعشاء» = maghrib +30",
      "«آخر الليل» = fajr -60",
      "الضحى = 09:30",
      "«قبل النوم» = 22:00",
      "«٥ إلا ربع» = 16:45",
    ]) {
      expect(PARSE_SYSTEM).toContain(rule);
    }
  });
});
