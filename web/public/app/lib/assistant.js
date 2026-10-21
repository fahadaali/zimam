// The in-app assistant on the web (api/DEVELOPMENT.md, «المساعد الذكي داخل التطبيق»): what a
// suggestion becomes, how it reads, and the Arabic sentence for each failure. The same wording as
// AssistantProblem and AssistantViews in the Apple app. Pure functions, no DOM; tested in
// test/assistant.test.mjs.
import { dualDate, isIsoDate, timeLabel } from "./dates.js";
import { arabicNumber } from "./numbers.js";
import { prayerPhrase } from "./prayer.js";

/** The assistant names priorities; tasks store 0 to 3. */
export const PRIORITY_FROM_NAME = { none: 0, low: 1, medium: 2, high: 3 };
const PRIORITY_NAMES = { 0: "بلا أولوية", 1: "منخفضة", 2: "متوسطة", 3: "عالية" };

export function suggestionPriority(value) {
  if (typeof value === "number" && value >= 0 && value <= 3) return Math.trunc(value);
  return PRIORITY_FROM_NAME[String(value ?? "").toLowerCase()] ?? 0;
}

/**
 * The task body for `POST /v1/tasks` from a suggestion. The prayer anchor wins over a clock time,
 * as on the server, and a time needs a day.
 */
export function suggestionToTask(s) {
  const dueDate = isIsoDate(s.dueDate) ? s.dueDate : null;
  const duePrayer = s.duePrayer || null;
  return {
    title: String(s.title ?? "").trim(),
    notes: s.notes ? String(s.notes) : null,
    dueDate,
    dueTime: !duePrayer && dueDate && /^\d{2}:\d{2}$/.test(s.dueTime ?? "") ? s.dueTime : null,
    duePrayer,
    duePrayerOffset: duePrayer ? (Number.isFinite(s.duePrayerOffset) ? s.duePrayerOffset : 0) : null,
    priority: suggestionPriority(s.priority),
    tags: Array.isArray(s.tags) ? s.tags.filter((t) => typeof t === "string" && t.trim()) : [],
    projectId: s.projectId || null,
  };
}

/** "14:30" → «٢:٣٠ م» (lib/dates.js). */
export const clockText = timeLabel;

/**
 * The suggestion card's lines, as label and value: [{ term: "العنوان", value }…]. Only what the
 * assistant filled in; dates in both calendars, the primary first.
 */
export function suggestionLines(task, { primary = "hijri", today, projectName = () => null } = {}) {
  const lines = [{ term: "العنوان", value: task.title }];
  const when = [];
  if (task.dueDate) when.push(dualDate(task.dueDate, { primary, today }));
  const prayer = prayerPhrase(task.duePrayer, task.duePrayerOffset);
  if (prayer) when.push(prayer);
  else if (task.dueTime) when.push(clockText(task.dueTime));
  if (when.length) lines.push({ term: "الموعد", value: when.join("، ") });
  if (task.priority) lines.push({ term: "الأولوية", value: PRIORITY_NAMES[task.priority] });
  const project = task.projectId ? projectName(task.projectId) : null;
  if (project) lines.push({ term: "المشروع", value: project });
  if (task.tags?.length) lines.push({ term: "الوسوم", value: task.tags.join("، ") });
  if (task.notes) lines.push({ term: "الملاحظات", value: task.notes });
  return lines;
}

/** «خطوة واحدة», «خطوتين», «٣ خطوات», «١١ خطوة». */
export function stepCount(n) {
  if (n === 1) return "خطوة واحدة";
  if (n === 2) return "خطوتين";
  if (n >= 3 && n <= 10) return `${arabicNumber(n)} خطوات`;
  return `${arabicNumber(n)} خطوة`;
}

/** The breakdown card's sentence. */
export function breakdownText(n) {
  return `قسّمت المهمة إلى ${stepCount(n)}. أزل ما لا تريده، ثم أضف الباقي مهامَّ فرعية.`;
}

/** Why a request failed: offline, quota, unavailable, pro, notFound, invalid, signedOut or other. */
export function assistantProblem(error, { online = true } = {}) {
  const code = error?.code;
  const status = error?.status;
  if (code === "network" || status === 0 || !online) return "offline";
  if (code === "pro_required") return "pro";
  if (code === "ai_quota_exceeded" || status === 429) return "quota";
  if (code === "ai_unavailable" || status === 503) return "unavailable";
  if (status === 404) return "notFound";
  if (status === 400) return "invalid";
  if (status === 401) return "signedOut";
  return "other";
}

/**
 * The sentence shown in place of a suggestion. A spent quota names the limit and the day it
 * renews in both calendars: «… (الحد ٣٠٠)، ولم يبقَ منها شيء. تتجدد في ٢١ جمادى الأولى، ١ نوفمبر.»
 */
export function assistantErrorText(error, { primary = "hijri", today, online = true } = {}) {
  switch (assistantProblem(error, { online })) {
    case "offline":
      return "المساعد يحتاج اتصالاً بالإنترنت. أضف المهمة يدوياً أو حاول حين يعود الاتصال.";
    case "quota": {
      const details = error?.details ?? {};
      let text = "استعملت كل طلبات المساعد لهذا الشهر";
      if (Number.isInteger(details.limit)) text += ` (الحد ${arabicNumber(details.limit)})`;
      text += "، ولم يبقَ منها شيء.";
      if (isIsoDate(details.resetsOn)) text += ` تتجدد في ${dualDate(details.resetsOn, { primary, today })}.`;
      return text;
    }
    case "unavailable":
      return "المساعد غير متاح الآن. حاول بعد قليل.";
    case "pro":
      return "المساعد الذكي من مزايا «زمام الاحترافية». يُشترى الاشتراك من تطبيق زمام على الآيفون أو الآيباد أو الماك (الإعدادات ← الاشتراك)، ثم يعمل هنا بالحساب نفسه.";
    case "notFound":
      return "لم نجد هذه المهمة، وربما حُذفت.";
    case "invalid":
      return "تعذّر فهم النص. اكتب جملة أقصر وأوضح.";
    case "signedOut":
      return "انتهت الجلسة. سجّل الدخول مرة أخرى.";
    default:
      return "تعذّر الوصول إلى المساعد. حاول مرة أخرى.";
  }
}

/** The device's time for `now`, with its offset: "2026-10-13T11:00:00+03:00". */
export function isoWithOffset(date = new Date()) {
  const pad = (n) => String(Math.trunc(Math.abs(n))).padStart(2, "0");
  const offset = -date.getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}` +
    `${sign}${pad(offset / 60)}:${pad(offset % 60)}`
  );
}
