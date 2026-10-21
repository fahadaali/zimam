// Imports from other apps (api/DEVELOPMENT.md, «الاستيراد»): the server reads a file, a Todoist
// token, or a provider's API after its OAuth flow, on its queue; the page starts the job, follows
// GET /v1/imports/:id, and shows what happened.
// Pure functions: no DOM, no network, no clock unless one is passed in.
import { dualDate } from "./dates.js";
import { arabicNumber } from "./numbers.js";

/** How often to ask for a running job, and the longest wait after repeated failures. */
export const POLL_MS = 1500;
export const QUEUED_POLL_MS = 2000;
export const MAX_POLL_MS = 30_000;

/** The server's limit when the sources have not loaded (MAX_UPLOAD_BYTES). */
export const DEFAULT_MAX_BYTES = 5 * 1024 * 1024;

export const TODOIST_TOKEN_URL = "https://app.todoist.com/app/settings/integrations/developer";

const SOURCES = {
  "todoist-oauth": {
    title: "Todoist: الربط بالحساب",
    subtitle: "كل المشاريع بإذن من حسابك",
    howTo:
      "تنتقل إلى Todoist لتأذن لزمام بقراءة مهامك، ثم تعود هنا. تُنقل المشاريع والأقسام والمهام المفتوحة كلها، دون نسخ أي رمز.",
  },
  "todoist-csv": {
    title: "Todoist: ملف مشروع",
    subtitle: "ملف CSV من «تصدير كقالب»",
    howTo:
      "في Todoist افتح المشروع، ثم من قائمته اختر «قوالب» ثم «تصدير كقالب»، واحفظ ملف CSV. كل ملف يصير مشروعاً في زمام. المهام المنجزة ليست في هذا التصدير.",
  },
  "todoist-api": {
    title: "Todoist: كل المشاريع",
    subtitle: "رمز API، فتُنقل المشاريع كلها",
    howTo:
      "انسخ رمز API الشخصي من Todoist: «الإعدادات» ثم «التكاملات» ثم «المطوّر»، والصقه هنا. تُنقل المشاريع والأقسام والمهام المفتوحة كلها. يُرسل الرمز مرة واحدة ولا يُحفظ.",
  },
  "ticktick-csv": {
    title: "TickTick",
    subtitle: "ملف النسخة الاحتياطية CSV",
    howTo: "في TickTick افتح «الإعدادات» ثم «الحساب» ثم «النسخ الاحتياطي»، ونزّل ملف CSV. تُنقل القوائم والمهام والمنجزة والتكرار والتذكيرات.",
  },
  "google-tasks-api": {
    title: "Google Tasks: الربط بالحساب",
    subtitle: "القوائم والمهام بحساب Google",
    howTo:
      "تنتقل إلى Google لتأذن لزمام بقراءة مهامك، ثم تعود هنا. تصير كل قائمة مشروعاً، وتُنقل المهام الفرعية والمواعيد والمنجزة. لا يتغيّر شيء في Google Tasks.",
  },
  "google-tasks": {
    title: "Google Tasks",
    subtitle: "ملف Tasks.json من Google Takeout",
    howTo: "من Google Takeout (takeout.google.com) اختر «Tasks» وحده ثم صدّر، وفك ضغط الملف واختر Tasks.json. كل قائمة تصير مشروعاً.",
  },
  csv: {
    title: "ملف CSV",
    subtitle: "أي جدول بصيغة CSV",
    howTo:
      "أي جدول صفّه الأول أسماء الأعمدة: العنوان (إلزامي)، والملاحظات، والتاريخ، والوقت، والمشروع، والقسم، والأولوية، والحالة، والوسوم. احفظه من Excel أو Numbers أو Google Sheets بصيغة CSV.",
  },
  "google-calendar": {
    title: "Google Calendar",
    subtitle: "أحداث تقاويمك مهاماً",
    howTo:
      "تنتقل إلى Google لتأذن لزمام بقراءة تقويمك، ثم تعود هنا. يصير كل تقويم ظاهر في Google Calendar مشروعاً، وكل حدث من آخر ٣٠ يوماً إلى سنة قادمة مهمة في موعده. لا يتغيّر شيء في تقويمك.",
  },
  "microsoft-todo": {
    title: "Microsoft To Do",
    subtitle: "القوائم والمهام بحساب Microsoft",
    howTo:
      "تنتقل إلى Microsoft لتأذن لزمام بقراءة مهامك، ثم تعود هنا. تصير كل قائمة مشروعاً، وقائمة «المهام» صندوق الوارد، وتُنقل الأهمية والمواعيد والتذكيرات والخطوات والمنجزة.",
  },
  notion: {
    title: "Notion",
    subtitle: "قاعدة بيانات مهام",
    howTo:
      "تنتقل إلى Notion وتختار قاعدة بيانات المهام (أو الصفحة التي فيها) لتشاركها مع زمام، ثم تعود هنا. تصير كل قاعدة مشروعاً: العنوان، والتاريخ، والحالة أو مربع الإنجاز، والأولوية، والوسوم.",
  },
  trello: {
    title: "Trello",
    subtitle: "اللوحات والبطاقات",
    howTo:
      "تنتقل إلى Trello لتأذن لزمام بالقراءة، ثم تعود هنا. تصير كل لوحة مشروع كانبان، وقوائمها أعمدة، وبطاقاتها مهام بمواعيدها وتسمياتها وقوائم التحقق.",
  },
  asana: {
    title: "Asana",
    subtitle: "المشاريع والأقسام والمهام",
    howTo:
      "تنتقل إلى Asana لتأذن لزمام بالقراءة، ثم تعود هنا. تُنقل المشاريع غير المؤرشفة بأقسامها ومهامها والمهام الفرعية والمواعيد والمنجزة.",
  },
  "ticktick-api": {
    title: "TickTick: الربط بالحساب",
    subtitle: "القوائم والمهام المفتوحة مباشرة",
    howTo:
      "تنتقل إلى TickTick لتأذن لزمام بقراءة مهامك، ثم تعود هنا. تُنقل القوائم وأعمدة الكانبان والمهام المفتوحة والتكرار والتذكيرات. وللمهام المنجزة استعمل ملف النسخة الاحتياطية.",
  },
};

/** Sources this page can start: files, tokens and OAuth flows. Inputs it does not know are left out. */
export function usableSources(sources = []) {
  return sources.filter((s) => s.input === "file" || s.input === "token" || s.input === "oauth");
}

/** Whether the server can start the source now (an OAuth source without its secrets cannot). */
export function isAvailable(source) {
  return source?.available !== false;
}

/** The first source that can be started, selected at first. */
export function firstAvailable(sources = []) {
  return sources.find(isAvailable) ?? null;
}

/** GET …/start?return=<this site's origin>: the provider's callback then comes back to this site. */
export function oauthStartPath(sourceId, origin) {
  return `/v1/imports/oauth/${encodeURIComponent(sourceId)}/start?return=${encodeURIComponent(origin)}`;
}

/** POST: starts the import a provider's callback left waiting, once the user agreed. */
export const OAUTH_CONFIRM_PATH = "/v1/imports/oauth/confirm";

/** How long the server keeps a returned flow waiting (PENDING_TTL_MS in api/src/imports/oauth.ts). */
export const PENDING_TTL_MS = 10 * 60_000;

/** sessionStorage: a provider's return kept through sign-in (Google's whole-tab flow loses the hash). */
export const PENDING_IMPORT_KEY = "zimam.pendingImport";

const isPendingId = (text) => typeof text === "string" && /^[A-Za-z0-9_-]{20,200}$/.test(text);
const isSourceId = (text) => typeof text === "string" && /^[a-z0-9-]{1,40}$/.test(text);
const isToken = (text) => typeof text === "string" && text.length > 0 && text.length <= 500;

/**
 * What the OAuth callback sent back in the route, all of it after `#`:
 * `#/import?pending=<id>&source=<id>` (and `&token=<…>` from Trello's page) when the provider
 * agreed and the import waits for the user's confirmation, `#/import?error=<code>` when it did
 * not. Null when the route carries neither. Nothing has started yet in either case.
 */
export function oauthReturn(hash = "") {
  const query = String(hash).split("?")[1] ?? "";
  const params = new URLSearchParams(query);
  const pending = params.get("pending");
  if (isPendingId(pending)) {
    const source = params.get("source");
    const token = params.get("token");
    return { pending, source: isSourceId(source) ? source : null, token: isToken(token) ? token : null, error: null };
  }
  const error = params.get("error");
  if (error) return { pending: null, source: null, token: null, error };
  return null;
}

/** What sessionStorage keeps of a return through sign-in: the same fields, and when. */
export function storedPending(back, now = Date.now()) {
  return JSON.stringify({ pending: back.pending, source: back.source ?? null, token: back.token ?? null, at: now });
}

/** A kept return, if it is well formed and the server still waits for it; null otherwise. */
export function readStoredPending(text, now = Date.now()) {
  let value;
  try {
    value = JSON.parse(text ?? "");
  } catch {
    return null;
  }
  if (!value || !isPendingId(value.pending) || typeof value.at !== "number" || now - value.at > PENDING_TTL_MS || value.at > now) return null;
  return {
    pending: value.pending,
    source: isSourceId(value.source) ? value.source : null,
    token: isToken(value.token) ? value.token : null,
    error: null,
  };
}

const PROVIDER_NAMES = {
  "todoist-oauth": "Todoist",
  "google-tasks-api": "Google Tasks",
  "google-calendar": "Google Calendar",
  "microsoft-todo": "Microsoft To Do",
  notion: "Notion",
  trello: "Trello",
  asana: "Asana",
  "ticktick-api": "TickTick",
};

/** The signed-in account as the confirmation names it: «فهد، fahad@example.com», or either alone. */
export function accountLabel(me) {
  const parts = [me?.name, me?.email].map((s) => (typeof s === "string" ? s.trim() : "")).filter(Boolean);
  return parts.length ? parts.join("، ") : null;
}

/**
 * The question before an OAuth import starts: «استيراد بيانات Notion إلى حسابك فهد؟». It names
 * the account the data will go to, so data never lands in an account the person does not
 * recognise (a provider link someone else started).
 */
export function confirmQuestion(sourceId, account) {
  const name = PROVIDER_NAMES[sourceId];
  const what = name ? `بيانات ${name}` : "البيانات";
  return account ? `استيراد ${what} إلى حسابك ${account}؟` : `استيراد ${what} إلى حسابك؟`;
}

export const CONFIRM_NOTE = "تأكّد أن هذا حسابك. إن لم تبدأ هذا الاستيراد بنفسك من زمام فاختر «إلغاء».";

/** Arabic text for a refused POST /v1/imports/oauth/confirm. */
export function confirmErrorText(error) {
  switch (error?.code) {
    case "not_found":
      return "انتهت صلاحية الطلب أو لا يخص حسابك. ابدأ الاستيراد مرة أخرى من حسابك في زمام.";
    case "expired":
      return "انتهت صلاحية طلب الاستيراد أو استُعمل من قبل. ابدأ الاستيراد مرة أخرى.";
    case "invalid_token":
    case "exchange_failed":
      return oauthErrorText("exchange_failed");
    default:
      return importErrorText(error, { input: "oauth" });
  }
}

const OAUTH_ERRORS = {
  denied: "لم يكتمل الإذن، فلم يبدأ الاستيراد. ابدأ مرة أخرى ووافق على الإذن إن أردت النقل.",
  provider_error: "رفض المصدر طلب الإذن. حاول مرة أخرى بعد قليل.",
  exchange_failed: "تعذّر إكمال الربط بالمصدر. ابدأ الاستيراد مرة أخرى.",
  pro_required: "الاستيراد من هذا المصدر من مزايا «زمام الاحترافية». اشترك من تطبيق زمام: الإعدادات ثم الاشتراك.",
  import_in_progress: "يجري استيراد آخر الآن. انتظر حتى ينتهي ثم ابدأ استيراداً جديداً.",
  import_unavailable: "تعذّر بدء الاستيراد الآن. أعد المحاولة بعد قليل.",
};

/** Arabic text for an error code the OAuth callback came back with. */
export function oauthErrorText(code) {
  return OAUTH_ERRORS[code] ?? OAUTH_ERRORS.exchange_failed;
}

/** The button that starts an OAuth source: «الربط بـ Notion». */
export function connectLabel(source) {
  return `الربط بـ ${source?.label ?? ""}`.trim();
}

export function sourceTitle(source) {
  return SOURCES[source?.id ?? source]?.title ?? source?.label ?? String(source ?? "");
}

export function sourceSubtitle(id) {
  return SOURCES[id]?.subtitle ?? "";
}

export function sourceHowTo(id) {
  return SOURCES[id]?.howTo ?? "صدّر مهامك من التطبيق الآخر ثم اختر الملف.";
}

/** The file input's `accept`: ".csv,.tsv". */
export function acceptList(source) {
  return (source?.extensions ?? []).join(",");
}

/** «CSV أو TSV». */
export function extensionsText(extensions = []) {
  return extensions.map((e) => e.replace(/^\./, "").toUpperCase()).join(" أو ");
}

const decimal = new Intl.NumberFormat("ar-SA-u-nu-arab", { maximumFractionDigits: 1, useGrouping: false });

/** «٥ ميغابايت», «٥٠٠ كيلوبايت». */
export function formatSize(bytes) {
  const mb = bytes / (1024 * 1024);
  if (mb >= 1) return `${decimal.format(mb)} ميغابايت`;
  return `${arabicNumber(Math.max(1, Math.round(bytes / 1024)))} كيلوبايت`;
}

export function limitText(maxFileBytes = DEFAULT_MAX_BYTES) {
  return `حجم الملف حتى ${formatSize(maxFileBytes)}.`;
}

const FILE_MESSAGES = {
  empty_file: () => "الملف فارغ. صدّره مرة أخرى ثم اختره.",
  file_too_large: ({ maxFileBytes = DEFAULT_MAX_BYTES }) =>
    `الملف أكبر من الحد المسموح (${formatSize(maxFileBytes)}). قسّمه إلى ملفات أصغر أو استورد المهام المفتوحة فقط.`,
  invalid_file_type: ({ extensions = [] }) =>
    extensions.length ? `هذا المصدر يقبل ملفات ${extensionsText(extensions)} فقط.` : "نوع الملف لا يناسب هذا المصدر.",
};

/**
 * Checks a chosen file the way POST /v1/imports does, before uploading it:
 * the extension (when there is one), then empty, then the size. Null when it is fine.
 */
export function checkFile(file, source, maxFileBytes = DEFAULT_MAX_BYTES) {
  if (!file) return { code: "no_file", message: "اختر الملف أولاً." };
  const extensions = source?.extensions ?? [];
  const match = /\.[^./\\]+$/.exec(file.name ?? "");
  const extension = match?.[0].toLowerCase();
  if (extension && extensions.length && !extensions.includes(extension)) {
    return { code: "invalid_file_type", message: FILE_MESSAGES.invalid_file_type({ extensions }) };
  }
  if (file.size === 0) return { code: "empty_file", message: FILE_MESSAGES.empty_file() };
  if (file.size > maxFileBytes) return { code: "file_too_large", message: FILE_MESSAGES.file_too_large({ maxFileBytes }) };
  return null;
}

/** A token as POST /v1/imports accepts it: 8–500 characters, no spaces. */
export function checkToken(text) {
  const token = String(text ?? "").trim();
  if (!token) return { code: "no_token", message: "الصق رمز API من Todoist." };
  if (token.length < 8 || token.length > 500 || /\s/.test(token)) {
    return { code: "invalid", message: "الرمز غير صالح. انسخه كاملاً من إعدادات المطوّر في Todoist." };
  }
  return null;
}

/** Arabic text for an error from the imports API (codes are stable and English). */
export function importErrorText(error, { maxFileBytes = DEFAULT_MAX_BYTES, extensions = [], input = "file" } = {}) {
  const code = error?.code;
  if (FILE_MESSAGES[code]) return FILE_MESSAGES[code]({ maxFileBytes, extensions });
  switch (code) {
    case "invalid":
      return input === "token"
        ? "الرمز غير صالح. انسخه كاملاً من إعدادات المطوّر في Todoist."
        : "تعذّر قراءة الطلب. تحقّق من الملف ثم حاول مرة أخرى.";
    case "invalid_source":
      return "هذا المصدر غير متاح. حدّث الصفحة ثم حاول مرة أخرى.";
    case "source_unavailable":
      return "هذا المصدر غير متاح الآن. حاول لاحقاً أو اختر مصدراً آخر.";
    case "import_in_progress":
      return "يجري استيراد آخر الآن. انتظر حتى ينتهي ثم ابدأ استيراداً جديداً.";
    case "import_unavailable":
      return "تعذّر بدء الاستيراد الآن. أعد المحاولة بعد قليل.";
    case "pro_required":
      return "الاستيراد من هذا المصدر من مزايا «زمام الاحترافية». اشترك من تطبيق زمام: الإعدادات ← الاشتراك.";
    case "not_found":
      return "لم نجد هذا الاستيراد.";
    case "unauthorized":
      return "انتهت الجلسة. سجّل الدخول مرة أخرى.";
    case "network":
      return "تعذّر الاتصال بالخادم. تحقق من اتصالك ثم حاول مرة أخرى.";
    default:
      return "حدث خطأ في الخادم. حاول بعد قليل.";
  }
}

const STATUS = { queued: "في الانتظار", running: "جارٍ الاستيراد", done: "اكتمل", failed: "تعذّر" };

export function statusText(status) {
  return STATUS[status] ?? STATUS.running;
}

export const isFinished = (job) => job?.status === "done" || job?.status === "failed";

/** «٥٠ من ١٢١», or what happens before the total is known. */
export function progressText(job) {
  if (job.status === "queued") return "ينتظر دوره في الطابور…";
  const { processed = 0, total = 0 } = job.progress ?? {};
  if (total <= 0) return "تُقرأ البيانات…";
  return `${arabicNumber(Math.min(processed, total))} من ${arabicNumber(total)}`;
}

/** 0–100 for a progress bar, or null while the total is unknown (an indeterminate bar). */
export function progressPercent(job) {
  if (job.status === "done") return 100;
  const { processed = 0, total = 0 } = job.progress ?? {};
  if (total <= 0) return null;
  return Math.min(100, Math.round((processed / total) * 100));
}

/** Counted «عنصر»: «عنصر واحد»، «عنصران»، «٣ عناصر»، «١١ عنصراً»، «١٠٠ عنصر». */
export function itemCount(n) {
  if (n === 0) return "لا عناصر";
  if (n === 1) return "عنصر واحد";
  if (n === 2) return "عنصران";
  const rest = n % 100;
  if (rest >= 3 && rest <= 10) return `${arabicNumber(n)} عناصر`;
  if (rest >= 11 && rest <= 99) return `${arabicNumber(n)} عنصراً`;
  return `${arabicNumber(n)} عنصر`;
}

/** One line for the job: progress while it runs, what it did once done, the server's Arabic message if it failed. */
export function summaryText(job) {
  if (job.status === "failed") return job.error?.message ?? "تعذّر الاستيراد.";
  if (job.status !== "done") return progressText(job);
  const c = job.counts ?? {};
  const parts = [];
  if (c.created > 0) parts.push(`أُضيف ${itemCount(c.created)}`);
  if (c.updated > 0) parts.push(`حُدِّث ${itemCount(c.updated)}`);
  if (parts.length === 0) return (c.unchanged ?? 0) + (c.skipped ?? 0) > 0 ? "لا جديد: كل شيء موجود في زمام." : "لم يُعثر على ما يُستورد.";
  return `${parts.join("، و")}.`;
}

const COUNT_LABELS = [
  ["created", "أُضيف"],
  ["updated", "حُدِّث"],
  ["unchanged", "لم يتغيّر"],
  ["skipped", "بقي كما عُدِّل في زمام"],
  ["failed", "تعذّر"],
];

/** The count rows to show, without zeros (the first row when everything is zero). */
export function countRows(counts = {}) {
  const rows = COUNT_LABELS.map(([key, label]) => ({ key, label, value: counts[key] ?? 0 }));
  const shown = rows.filter((r) => r.value > 0);
  return shown.length ? shown : rows.slice(0, 1);
}

/** How long to wait before asking again: longer while queued, and backing off after failures. */
export function nextPollDelay(job, failures = 0) {
  const base = job?.status === "queued" ? QUEUED_POLL_MS : POLL_MS;
  return Math.min(MAX_POLL_MS, base * 2 ** Math.min(failures, 5));
}

/** The calendar day of an instant in a time zone (the viewer's by default): "2026-10-13". */
export function dayOf(ms, timeZone) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(ms));
  const get = (type) => parts.find((p) => p.type === type)?.value;
  return `${get("year")}-${get("month")}-${get("day")}`;
}

/** When a job started, in both calendars with the time: «٢ جمادى الأولى، ١٣ أكتوبر، ٣:٠٠ م». */
export function jobDate(ms, { primary = "hijri", today, timeZone } = {}) {
  const day = dayOf(ms, timeZone);
  const time = new Intl.DateTimeFormat("ar-SA-u-nu-arab", { timeZone, hour: "numeric", minute: "2-digit" }).format(new Date(ms));
  return `${dualDate(day, { primary, today: today ?? dayOf(Date.now(), timeZone) })}، ${time}`;
}
