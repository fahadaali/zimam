import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DEFAULT_MAX_BYTES,
  acceptList,
  checkFile,
  checkToken,
  countRows,
  dayOf,
  formatSize,
  importErrorText,
  isFinished,
  itemCount,
  jobDate,
  limitText,
  nextPollDelay,
  progressPercent,
  progressText,
  sourceTitle,
  statusText,
  summaryText,
  usableSources,
} from "../public/app/lib/imports.js";

const csv = { id: "todoist-csv", label: "Todoist", input: "file", extensions: [".csv"] };
const generic = { id: "csv", label: "CSV", input: "file", extensions: [".csv", ".tsv", ".txt"] };
const job = (extra = {}) => ({
  id: "0b9c6f8e-6f2c-4a4e-9a51-1d2c3b4a5e6f",
  source: "todoist-csv",
  status: "running",
  fileName: "زواج.csv",
  progress: { processed: 0, total: 0 },
  counts: { created: 0, updated: 0, unchanged: 0, skipped: 0, failed: 0, byEntity: {} },
  warnings: [],
  errors: [],
  error: null,
  createdAt: 0,
  updatedAt: 0,
  finishedAt: null,
  ...extra,
});

test("sizes and the upload limit read in Arabic", () => {
  assert.equal(formatSize(DEFAULT_MAX_BYTES), "٥ ميغابايت");
  assert.equal(formatSize(1.5 * 1024 * 1024), "١٫٥ ميغابايت");
  assert.equal(formatSize(500 * 1024), "٥٠٠ كيلوبايت");
  assert.equal(limitText(), "حجم الملف حتى ٥ ميغابايت.");
});

test("a file is checked as the server checks it: type, then empty, then size", () => {
  assert.equal(checkFile({ name: "مشروع.CSV", size: 1200 }, csv), null);
  assert.equal(checkFile({ name: "Tasks.json", size: 1200 }, csv).code, "invalid_file_type");
  assert.equal(checkFile({ name: "Tasks.json", size: 1200 }, csv).message, "هذا المصدر يقبل ملفات CSV فقط.");
  assert.equal(checkFile({ name: "a.csv", size: 0 }, csv).code, "empty_file");
  assert.equal(checkFile({ name: "a.csv", size: DEFAULT_MAX_BYTES }, csv), null);
  const large = checkFile({ name: "a.csv", size: DEFAULT_MAX_BYTES + 1 }, csv);
  assert.equal(large.code, "file_too_large");
  assert.match(large.message, /٥ ميغابايت/);
  assert.equal(checkFile({ name: "export", size: 10 }, csv), null, "no extension: the server reads the content");
  assert.equal(checkFile(undefined, csv).code, "no_file");
  assert.equal(checkFile({ name: "a.tsv", size: 10 }, generic), null);
  assert.equal(acceptList(generic), ".csv,.tsv,.txt");
});

test("a Todoist token is pasted whole", () => {
  assert.equal(checkToken("  0123456789abcdef0123456789abcdef01234567 "), null);
  assert.equal(checkToken("").code, "no_token");
  assert.equal(checkToken("short").code, "invalid");
  assert.equal(checkToken("abc def ghi jkl").code, "invalid");
});

test("API errors read in Arabic", () => {
  assert.equal(importErrorText({ code: "import_in_progress" }), "يجري استيراد آخر الآن. انتظر حتى ينتهي ثم ابدأ استيراداً جديداً.");
  assert.match(importErrorText({ code: "file_too_large" }, { maxFileBytes: DEFAULT_MAX_BYTES }), /٥ ميغابايت/);
  assert.equal(importErrorText({ code: "invalid_file_type" }, { extensions: [".json"] }), "هذا المصدر يقبل ملفات JSON فقط.");
  assert.equal(importErrorText({ code: "empty_file" }), "الملف فارغ. صدّره مرة أخرى ثم اختره.");
  assert.match(importErrorText({ code: "invalid" }, { input: "token" }), /الرمز غير صالح/);
  assert.equal(importErrorText({ code: "import_unavailable" }), "تعذّر بدء الاستيراد الآن. أعد المحاولة بعد قليل.");
  assert.equal(importErrorText({ code: "something_new" }), "حدث خطأ في الخادم. حاول بعد قليل.");
});

test("progress text and percent", () => {
  assert.equal(progressText(job({ status: "queued" })), "ينتظر دوره في الطابور…");
  assert.equal(progressText(job()), "تُقرأ البيانات…");
  assert.equal(progressPercent(job()), null);
  const halfway = job({ progress: { processed: 50, total: 121 } });
  assert.equal(progressText(halfway), "٥٠ من ١٢١");
  assert.equal(progressPercent(halfway), 41);
  assert.equal(progressPercent(job({ status: "done", progress: { processed: 0, total: 0 } })), 100);
  assert.equal(statusText("running"), "جارٍ الاستيراد");
  assert.equal(statusText("done"), "اكتمل");
  assert.equal(statusText("failed"), "تعذّر");
});

test("a finished job's summary and counts", () => {
  const done = job({ status: "done", counts: { created: 48, updated: 2, unchanged: 0, skipped: 0, failed: 0 } });
  assert.ok(isFinished(done));
  assert.equal(summaryText(done), "أُضيف ٤٨ عنصراً، وحُدِّث عنصران.");
  assert.deepEqual(countRows(done.counts).map((r) => r.label), ["أُضيف", "حُدِّث"]);
  assert.deepEqual(countRows({}).map((r) => r.value), [0]);
  assert.equal(summaryText(job({ status: "done", counts: { created: 0, updated: 0, unchanged: 50, skipped: 0, failed: 0 } })), "لا جديد: كل شيء موجود في زمام.");

  const failed = job({ status: "failed", error: { code: "token_rejected", message: "رفض Todoist الرمز. انسخه مرة أخرى." } });
  assert.ok(isFinished(failed));
  assert.equal(summaryText(failed), "رفض Todoist الرمز. انسخه مرة أخرى.");
  assert.ok(!isFinished(job({ status: "queued" })));
});

test("counted items agree with the number", () => {
  assert.equal(itemCount(1), "عنصر واحد");
  assert.equal(itemCount(2), "عنصران");
  assert.equal(itemCount(7), "٧ عناصر");
  assert.equal(itemCount(48), "٤٨ عنصراً");
  assert.equal(itemCount(100), "١٠٠ عنصر");
  assert.equal(itemCount(103), "١٠٣ عناصر");
});

test("polling waits longer while queued and backs off after failures", () => {
  assert.equal(nextPollDelay(job()), 1500);
  assert.equal(nextPollDelay(job({ status: "queued" })), 2000);
  assert.equal(nextPollDelay(job(), 2), 6000);
  assert.equal(nextPollDelay(job(), 10), 30_000);
});

test("sources: names, and only the kinds this page can start", () => {
  assert.equal(sourceTitle(csv), "Todoist: ملف مشروع");
  assert.equal(sourceTitle({ id: "trello", label: "Trello" }), "Trello");
  assert.deepEqual(
    usableSources([csv, { id: "todoist-api", input: "token" }, { id: "trello", input: "oauth" }]).map((s) => s.id),
    ["todoist-csv", "todoist-api"],
  );
});

test("job dates show both calendars and the time, with the Arabic comma", () => {
  // 2026-10-13 12:00 UTC is 15:00 in Riyadh: 2 Jumada al-Ula 1448.
  const ms = Date.UTC(2026, 9, 13, 12);
  assert.equal(dayOf(ms, "Asia/Riyadh"), "2026-10-13");
  const text = jobDate(ms, { primary: "hijri", today: "2026-10-15", timeZone: "Asia/Riyadh" });
  assert.match(text, /^٢ جمادى الأولى، ١٣ أكتوبر، ٣:٠٠/);
  assert.ok(!text.includes("·"));
  const gregorianFirst = jobDate(ms, { primary: "gregorian", today: "2026-10-15", timeZone: "Asia/Riyadh" });
  assert.match(gregorianFirst, /^١٣ أكتوبر، ٢ جمادى الأولى، /);
  // Another year adds the years.
  assert.match(jobDate(ms, { today: "2027-01-02", timeZone: "Asia/Riyadh" }), /١٤٤٨/);
});
