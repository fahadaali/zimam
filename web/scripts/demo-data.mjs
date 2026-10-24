// Demo data for the website's screenshots (scripts/screenshots.mjs), as docs/appstore/screenshots.md
// plans the App Store ones: projects «العمل» and «البيت» and «سفر العائلة», short real-life tasks,
// some at a prayer, some spanning days, no names of real people and no kashida in titles.
// `answer()` plays the API (api/DEVELOPMENT.md) for the web app at a fixed moment.

/** The moment every screenshot shows: Wednesday morning, 9:41 in Riyadh. */
export const NOW = "2026-10-21T09:41:00+03:00";
export const TODAY = "2026-10-21";
const TIME_ZONE = "Asia/Riyadh";

const day = (offset) => new Date(Date.parse(`${TODAY}T12:00:00Z`) + offset * 86_400_000).toISOString().slice(0, 10);

const projects = [
  { id: "p-work", name: "العمل", view: "list", taskCount: 9, doneCount: 3, sortOrder: 0 },
  { id: "p-home", name: "البيت", view: "kanban", taskCount: 6, doneCount: 1, sortOrder: 1 },
  { id: "p-trip", name: "سفر العائلة", view: "list", taskCount: 5, doneCount: 2, sortOrder: 2 },
].map((p) => ({ ownerId: "u-demo", parentId: null, kind: "project", role: "owner", archivedAt: null, createdAt: 1, updatedAt: 1, ...p }));

const sections = {
  "p-work": [
    { id: "s-contracts", name: "العقود", sortOrder: 0 },
    { id: "s-reports", name: "التقارير", sortOrder: 1 },
  ],
  "p-home": [
    { id: "s-todo", name: "للتنفيذ", sortOrder: 0 },
    { id: "s-doing", name: "قيد العمل", sortOrder: 1 },
    { id: "s-waiting", name: "بانتظار", sortOrder: 2 },
  ],
  "p-trip": [],
};
for (const [projectId, list] of Object.entries(sections)) for (const s of list) Object.assign(s, { projectId, createdAt: 1, updatedAt: 1 });

let order = 0;
const task = (fields) => ({
  ownerId: "u-demo",
  projectId: null,
  sectionId: null,
  parentId: null,
  notes: null,
  status: "todo",
  priority: 0,
  tags: [],
  dueDate: null,
  startDate: null,
  dueTime: null,
  duePrayer: null,
  duePrayerOffset: null,
  recurrence: null,
  assigneeId: null,
  sortOrder: order++,
  completedAt: null,
  createdAt: order,
  updatedAt: 1,
  ...fields,
});

export const tasks = [
  task({ id: "t-contract", title: "مراجعة العقد مع المحامي", notes: "النسخة الثانية من البنود والملاحق", dueDate: TODAY, duePrayer: "maghrib", duePrayerOffset: 20, priority: 3, projectId: "p-work", sectionId: "s-contracts", tags: ["عمل", "عاجل"], recurrence: null }),
  task({ id: "t-mother", title: "الاتصال بالوالدة", dueDate: TODAY, duePrayer: "asr", duePrayerOffset: 0, recurrence: "FREQ=DAILY" }),
  task({ id: "t-report", title: "تسليم تقرير الربع", dueDate: TODAY, dueTime: "14:00", priority: 2, projectId: "p-work", sectionId: "s-reports" }),
  task({ id: "t-quran", title: "قراءة ورد اليوم", dueDate: TODAY, duePrayer: "fajr", duePrayerOffset: 20, priority: 1, recurrence: "FREQ=DAILY" }),
  task({ id: "t-license", title: "تجديد رخصة القيادة", dueDate: day(-2), priority: 2 }),
  task({ id: "t-flights", title: "حجز تذاكر الطيران", dueDate: day(1), priority: 2, projectId: "p-trip" }),
  task({ id: "t-hotel", title: "حجز الفندق", dueDate: day(2), projectId: "p-trip", tags: ["سفر"] }),
  task({ id: "t-bags", title: "تجهيز الحقائب", dueDate: day(8), projectId: "p-trip" }),
  task({ id: "t-visa", title: "استخراج التأشيرات", startDate: day(2), dueDate: day(6), priority: 3, projectId: "p-trip" }),
  task({ id: "t-team", title: "اجتماع الفريق الأسبوعي", dueDate: day(4), dueTime: "10:00", recurrence: "FREQ=WEEKLY;BYDAY=SU", projectId: "p-work", sectionId: "s-reports" }),
  task({ id: "t-deck", title: "إعداد عرض المشروع", startDate: day(-1), dueDate: day(6), priority: 2, projectId: "p-work", sectionId: "s-reports" }),
  task({ id: "t-budget", title: "مراجعة ميزانية الربع القادم", dueDate: day(3), priority: 1, projectId: "p-work" }),
  task({ id: "t-supplier", title: "توقيع عقد المورّد", dueDate: day(9), priority: 2, projectId: "p-work", sectionId: "s-contracts" }),
  task({ id: "t-ac", title: "صيانة المكيّف", dueDate: day(3), priority: 2, projectId: "p-home", sectionId: "s-todo" }),
  task({ id: "t-bill", title: "دفع فاتورة الكهرباء", dueDate: day(5), duePrayer: "isha", duePrayerOffset: 0, priority: 3, projectId: "p-home", sectionId: "s-todo" }),
  task({ id: "t-gift", title: "شراء هدية العيد", startDate: day(4), dueDate: day(7), projectId: "p-home", sectionId: "s-doing" }),
  task({ id: "t-books", title: "ترتيب المكتبة", projectId: "p-home", sectionId: "s-doing", priority: 1 }),
  task({ id: "t-curtains", title: "تركيب الستائر", dueDate: day(10), projectId: "p-home", sectionId: "s-waiting" }),
  task({ id: "t-cv", title: "تحديث السيرة الذاتية", priority: 1 }),
  task({ id: "t-read", title: "قراءة كتاب العادات الذرية" }),
  // Subtasks of the contract review, and a few done tasks for the projects' progress.
  task({ id: "t-sub1", title: "قراءة البند السابع", parentId: "t-contract", projectId: "p-work", status: "done" }),
  task({ id: "t-sub2", title: "تجهيز الملاحظات للمحامي", parentId: "t-contract", projectId: "p-work" }),
  task({ id: "t-done1", title: "إرسال الفاتورة للعميل", dueDate: day(-3), projectId: "p-work", status: "done" }),
  task({ id: "t-done2", title: "تأكيد موعد الاجتماع", dueDate: day(-1), projectId: "p-work", status: "done" }),
];

const reminders = {
  "t-contract": [
    { id: "r1", kind: "relative", offsetMinutes: 0 },
    { id: "r2", kind: "relative", offsetMinutes: -60 },
    { id: "r3", kind: "prayer", prayer: "asr", offsetMinutes: 0 },
  ],
};

const me = {
  id: "u-demo",
  name: "سارة",
  email: "demo@zimam.work",
  avatarVersion: null,
  settings: {
    calendar: "hijri",
    prayerMethod: "ummAlQura",
    asrMadhab: "shafi",
    prayerAlerts: {},
    weekStart: 0,
    timeZone: TIME_ZONE,
    location: { latitude: 24.71, longitude: 46.68 },
  },
};

/** Riyadh's prayer times in late October, the same each day of the month shown. */
function prayerDay(date) {
  const base = Date.parse(`${date}T00:00:00+03:00`);
  const at = (h, m) => ({ time: `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`, at: base + (h * 60 + m) * 60_000 });
  return { date, times: { fajr: at(4, 39), sunrise: at(5, 57), dhuhr: at(11, 45), asr: at(15, 5), maghrib: at(17, 32), isha: at(19, 2) } };
}

/** What the assistant reads in «ذكرني أراجع العقد بعد المغرب يوم الخميس». */
const suggestion = {
  title: "مراجعة العقد",
  notes: null,
  dueDate: day(1),
  dueTime: null,
  duePrayer: "maghrib",
  duePrayerOffset: 0,
  priority: "medium",
  tags: ["عمل"],
  projectId: "p-work",
};

const open = (t) => t.status !== "done";

/** The API's answer to a request, as `{ status, body }`. */
export function answer(method, url) {
  const u = new URL(url);
  const path = u.pathname;
  const q = u.searchParams;
  const ok = (body) => ({ status: 200, body });

  if (path === "/v1/me") return ok(me);
  if (path === "/v1/me/avatar") return { status: 404, body: { error: { code: "not_found", message: "No photo" } } };
  if (path === "/v1/projects") return ok({ projects: projects.map((p) => ({ ...p, sections: sections[p.id] ?? [] })) });
  const project = path.match(/^\/v1\/projects\/([^/]+)$/);
  if (project) {
    const p = projects.find((x) => x.id === project[1]);
    return p ? ok({ ...p, sections: sections[p.id] ?? [] }) : { status: 404, body: { error: { code: "not_found" } } };
  }
  if (/^\/v1\/projects\/[^/]+\/(members|invites)$/.test(path)) return ok({ members: [], invites: [] });
  if (/^\/v1\/tasks\/[^/]+\/reminders$/.test(path)) return ok({ reminders: (reminders[path.split("/")[3]] ?? []).map((r) => ({ ...r, taskId: path.split("/")[3], at: null, prayer: r.prayer ?? null, location: null, updatedAt: 1 })) });
  if (/^\/v1\/tasks\/[^/]+\/comments$/.test(path)) return ok({ comments: [] });
  if (/^\/v1\/tasks\/[^/]+\/attachments$/.test(path)) return ok({ attachments: [], maxFileBytes: 26_214_400, canAdd: true });
  const one = path.match(/^\/v1\/tasks\/([^/]+)$/);
  if (one && method === "GET") {
    const t = tasks.find((x) => x.id === one[1]);
    return t ? ok(t) : { status: 404, body: { error: { code: "not_found" } } };
  }
  if (path === "/v1/tasks") {
    let list = tasks;
    if (q.get("status") === "open") list = list.filter(open);
    if (q.get("dueFrom")) list = list.filter((t) => t.dueDate && t.dueDate >= q.get("dueFrom"));
    if (q.get("dueTo")) list = list.filter((t) => t.dueDate && t.dueDate <= q.get("dueTo"));
    if (q.get("projectId") === "inbox") list = list.filter((t) => !t.projectId);
    else if (q.get("projectId")) list = list.filter((t) => t.projectId === q.get("projectId"));
    if (q.get("q")) list = list.filter((t) => t.title.includes(q.get("q")));
    if (q.get("parentId")) list = list.filter((t) => t.parentId === q.get("parentId"));
    const offset = Number(q.get("offset") ?? 0);
    return ok({ tasks: list.slice(offset, offset + Number(q.get("limit") ?? 100)) });
  }
  if (path === "/v1/prayers") {
    const from = q.get("from") ?? TODAY;
    const to = q.get("to") ?? from;
    const days = [];
    for (let d = from; d <= to; d = new Date(Date.parse(`${d}T12:00:00Z`) + 86_400_000).toISOString().slice(0, 10)) days.push(prayerDay(d));
    return ok({ timeZone: TIME_ZONE, method: "ummAlQura", asrMadhab: "shafi", location: me.settings.location, days });
  }
  if (path === "/v1/assistant/parse") return ok(suggestion);
  if (path.startsWith("/v1/assistant/summary")) return ok({ text: "يومك فيه أربع مهام: أولها قراءة الورد بعد الفجر، وأهمها مراجعة العقد بعد المغرب." });
  // No live updates in a screenshot.
  if (path.startsWith("/v1/realtime")) return { status: 503, body: { error: { code: "internal" } } };
  return ok({});
}
