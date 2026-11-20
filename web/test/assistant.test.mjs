import assert from "node:assert/strict";
import { test } from "node:test";
import {
  assistantErrorText,
  assistantProblem,
  breakdownText,
  isoWithOffset,
  stepCount,
  waitText,
  suggestionLines,
  suggestionPriority,
  suggestionToTask,
} from "../public/app/lib/assistant.js";
import { ApiError } from "../public/app/lib/api.js";

const quota = new ApiError(429, "ai_quota_exceeded", "limit", { code: "ai_quota_exceeded", limit: 300, resetsOn: "2026-11-01" });

test("classifies the assistant's failures", () => {
  assert.equal(assistantProblem(quota), "quota");
  assert.equal(assistantProblem(new ApiError(503, "ai_unavailable", "")), "unavailable");
  assert.equal(assistantProblem(new ApiError(403, "pro_required", "")), "pro");
  assert.equal(assistantProblem(new ApiError(0, "network", "")), "offline");
  assert.equal(assistantProblem(new ApiError(500, "internal", ""), { online: false }), "offline");
  assert.equal(assistantProblem(new ApiError(404, "not_found", "")), "notFound");
  assert.equal(assistantProblem(new ApiError(400, "invalid", "")), "invalid");
  assert.equal(assistantProblem(new ApiError(500, "internal", "")), "other");
});

test("a spent quota names the limit and the renewal day in both calendars", () => {
  const text = assistantErrorText(quota, { primary: "hijri", today: "2026-10-15" });
  assert.equal(text, "استعملت كل طلبات المساعد لهذا الشهر (الحد ٣٠٠)، ولم يبقَ منها شيء. تتجدد في ٢١ جمادى الأولى، ١ نوفمبر.");
  assert.ok(!text.includes("·"));
  const gregorianFirst = assistantErrorText(quota, { primary: "gregorian", today: "2026-10-15" });
  assert.ok(gregorianFirst.endsWith("تتجدد في ١ نوفمبر، ٢١ جمادى الأولى."), gregorianFirst);
  // In December the renewal falls in the next year, so years are shown.
  const december = new ApiError(429, "ai_quota_exceeded", "", { limit: 300, resetsOn: "2027-01-01" });
  assert.match(assistantErrorText(december, { today: "2026-12-20" }), /١٤٤٨هـ، ١ يناير ٢٠٢٧/);
  // Without the details, the sentence alone.
  assert.equal(assistantErrorText(new ApiError(429, "ai_quota_exceeded", "")), "استعملت كل طلبات المساعد لهذا الشهر، ولم يبقَ منها شيء.");
});

test("the other failures read as the app's sentences", () => {
  assert.equal(assistantErrorText(new ApiError(503, "ai_unavailable", "")), "المساعد غير متاح الآن. حاول بعد قليل.");
  assert.match(assistantErrorText(new ApiError(0, "network", "")), /يحتاج اتصالاً بالإنترنت/);
  const pro = assistantErrorText(new ApiError(403, "pro_required", ""));
  assert.match(pro, /«زمام الاحترافية»/);
  assert.match(pro, /من تطبيق زمام/);
});

test("fair-use limits and a busy assistant are not the month's quota", () => {
  const minute = new ApiError(429, "ai_rate_limited", "", { code: "ai_rate_limited", scope: "minute", limit: 10, retryAfter: 42 });
  const day = new ApiError(429, "ai_rate_limited", "", { code: "ai_rate_limited", scope: "day", limit: 100, retryAfter: 5 * 3600 - 30 });
  const busy = new ApiError(503, "ai_busy", "", { code: "ai_busy", retryAfter: 90 });
  assert.equal(assistantProblem(minute), "rateLimited");
  assert.equal(assistantProblem(day), "rateLimited");
  assert.equal(assistantProblem(busy), "busy");
  assert.equal(assistantProblem(new ApiError(429, "too_many", "")), "rateLimited", "a 429 that is not the quota passes on its own");
  assert.equal(assistantProblem(new ApiError(503, "unknown", "")), "unavailable");

  assert.equal(assistantErrorText(minute), "أرسلت إلى المساعد طلبات كثيرة في وقت قصير. حاول بعد دقيقة.");
  assert.equal(assistantErrorText(day), "بلغت حد طلبات المساعد لهذا اليوم (الحد ١٠٠). حاول بعد ٥ ساعات.");
  assert.equal(assistantErrorText(busy), "المساعد مشغول الآن بطلبات كثيرة. حاول بعد دقيقتين.");
  // Without retryAfter or the limit, the sentence still says what to do.
  assert.equal(assistantErrorText(new ApiError(429, "ai_rate_limited", "", { scope: "day" })), "بلغت حد طلبات المساعد لهذا اليوم. حاول بعد قليل.");
  assert.equal(assistantErrorText(new ApiError(503, "ai_busy", "")), "المساعد مشغول الآن بطلبات كثيرة. حاول بعد قليل.");
});

test("the wait reads in whole minutes or hours, rounded up", () => {
  assert.equal(waitText(1), "دقيقة");
  assert.equal(waitText(60), "دقيقة");
  assert.equal(waitText(61), "دقيقتين");
  assert.equal(waitText(5 * 60), "٥ دقائق");
  assert.equal(waitText(15 * 60), "١٥ دقيقة");
  assert.equal(waitText(3600), "ساعة");
  assert.equal(waitText(3601), "ساعتين");
  assert.equal(waitText(11 * 3600), "١١ ساعة");
  assert.equal(waitText(0), null);
  assert.equal(waitText(Number.NaN), null);
  assert.equal(waitText(undefined), null);
});

test("a suggestion becomes a task body; the prayer wins over a clock time", () => {
  const task = suggestionToTask({
    title: "مراجعة العقد",
    dueDate: "2026-10-15",
    dueTime: "18:00",
    duePrayer: "maghrib",
    duePrayerOffset: 20,
    priority: "high",
    tags: ["عمل"],
    projectId: "p1",
  });
  assert.deepEqual(task, {
    title: "مراجعة العقد",
    notes: null,
    dueDate: "2026-10-15",
    dueTime: null,
    duePrayer: "maghrib",
    duePrayerOffset: 20,
    priority: 3,
    tags: ["عمل"],
    projectId: "p1",
  });
  assert.equal(suggestionToTask({ title: "x", dueTime: "09:00" }).dueTime, null, "a time needs a day");
  assert.equal(suggestionToTask({ title: "x", dueDate: "2026-10-15", dueTime: "09:00" }).dueTime, "09:00");
  assert.equal(suggestionPriority("medium"), 2);
  assert.equal(suggestionPriority(1), 1);
  assert.equal(suggestionPriority("urgent"), 0);
});

test("the suggestion card lists what the assistant filled in", () => {
  const lines = suggestionLines(
    { title: "مراجعة العقد", dueDate: "2026-10-15", duePrayer: "maghrib", duePrayerOffset: 20, priority: 3, tags: ["عمل", "قانون"], projectId: "p1" },
    { primary: "hijri", today: "2026-10-15", projectName: (id) => (id === "p1" ? "المكتب" : null) },
  );
  assert.deepEqual(lines, [
    { term: "العنوان", value: "مراجعة العقد" },
    { term: "الموعد", value: "٤ جمادى الأولى، ١٥ أكتوبر، بعد المغرب بـ٢٠ د" },
    { term: "الأولوية", value: "عالية" },
    { term: "المشروع", value: "المكتب" },
    { term: "الوسوم", value: "عمل، قانون" },
  ]);
  assert.deepEqual(suggestionLines({ title: "x", priority: 0, tags: [] }), [{ term: "العنوان", value: "x" }]);
});

test("step counts read naturally", () => {
  assert.equal(stepCount(1), "خطوة واحدة");
  assert.equal(stepCount(2), "خطوتين");
  assert.equal(stepCount(4), "٤ خطوات");
  assert.equal(stepCount(11), "١١ خطوة");
  assert.equal(breakdownText(4), "قسّمت المهمة إلى ٤ خطوات. أزل ما لا تريده، ثم أضف الباقي مهامَّ فرعية.");
});

test("the device time goes with its offset", () => {
  const text = isoWithOffset(new Date());
  assert.match(text, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/);
  assert.equal(new Date(text).getTime() <= Date.now(), true);
});
