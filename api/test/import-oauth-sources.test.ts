import { describe, expect, it } from "vitest";
import { flatten } from "../src/imports/apply";
import type { ImportedTask } from "../src/imports/model";
import { zimamRule } from "../src/imports/recurrence";
import { derivedKey } from "../src/imports/source";
import { type AsanaData, mapAsana } from "../src/imports/sources/asana";
import { type GoogleCalendarData, isChosenCalendar, mapGoogleCalendar } from "../src/imports/sources/google-calendar";
import { mapMicrosoftTodo, type MicrosoftTodoData, todoRecurrence } from "../src/imports/sources/microsoft-todo";
import { mapNotion, type NotionData, notionMapping } from "../src/imports/sources/notion";
import { htmlToText } from "../src/imports/sources/provider-http";
import { mapTickTickApi, type TickTickData } from "../src/imports/sources/ticktick-api";
import { mapTrello, parseTrelloCredential, type TrelloData, trelloCredential } from "../src/imports/sources/trello";
import asanaJson from "./fixtures/imports/asana.json?raw";
import googleCalendarJson from "./fixtures/imports/google-calendar.json?raw";
import microsoftTodoJson from "./fixtures/imports/microsoft-todo.json?raw";
import notionJson from "./fixtures/imports/notion.json?raw";
import tickTickApiJson from "./fixtures/imports/ticktick-api.json?raw";
import trelloJson from "./fixtures/imports/trello.json?raw";

const RIYADH = { timeZone: "Asia/Riyadh", fileName: null };
const byTitle = (tasks: ImportedTask[], title: string) => {
  const task = tasks.find((t) => t.title === title);
  if (!task) throw new Error(`no task «${title}» in ${tasks.map((t) => t.title).join(" | ")}`);
  return task;
};

describe("Recurrence for Zimam", () => {
  it("keeps what the apps repeat, and drops parts that restate the due day", () => {
    // 2026-10-15 is a Thursday.
    expect(zimamRule("RRULE:FREQ=WEEKLY;WKST=SU;BYDAY=TH", "2026-10-15")).toBe("FREQ=WEEKLY");
    expect(zimamRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=TH,MO", "2026-10-15")).toBe("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH");
    expect(zimamRule("FREQ=DAILY;INTERVAL=1;UNTIL=20261231T205959Z", "2026-10-15")).toBe("FREQ=DAILY;UNTIL=20261231");
    expect(zimamRule("FREQ=MONTHLY;BYMONTHDAY=15;COUNT=4", "2026-10-15")).toBe("FREQ=MONTHLY;COUNT=4");
    expect(zimamRule("FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=15", "2026-10-15")).toBe("FREQ=YEARLY");
  });

  it("refuses what would repeat on other days", () => {
    expect(zimamRule("FREQ=MONTHLY;BYDAY=2MO", "2026-10-12")).toBeNull();
    expect(zimamRule("FREQ=MONTHLY;BYMONTHDAY=1,15", "2026-10-15")).toBeNull();
    expect(zimamRule("FREQ=MONTHLY;BYSETPOS=-1;BYDAY=FR", "2026-10-30")).toBeNull();
    expect(zimamRule("FREQ=HOURLY", "2026-10-15")).toBeNull();
    expect(zimamRule("FREQ=DAILY;INTERVAL=0", "2026-10-15")).toBeNull();
  });
});

describe("HTML notes", () => {
  it("keeps the lines and drops the tags", () => {
    expect(htmlToText("<p>جدول الأعمال</p><ul><li>الميزانية</li><li>الخطة</li></ul>")).toBe("جدول الأعمال\n• الميزانية\n• الخطة");
    expect(htmlToText("سطر<br>آخر &amp; <b>غامق</b>")).toBe("سطر\nآخر & غامق");
  });
});

describe("Google Calendar", () => {
  const data = JSON.parse(googleCalendarJson) as GoogleCalendarData;
  const bundle = mapGoogleCalendar(data, RIYADH);

  it("imports the primary and the ticked calendars, not Google's own or unticked ones", () => {
    expect(bundle.projects.map((p) => [p.name, p.view])).toEqual([
      ["fahad@example.com", "calendar"],
      ["العائلة", "calendar"],
    ]);
    expect(isChosenCalendar({ id: "x@group.calendar.google.com", selected: false })).toBe(false);
    expect(isChosenCalendar({ id: "en.sa#holiday@group.v.calendar.google.com", selected: true })).toBe(false);
  });

  it("maps events to tasks due when they start, in the user's zone", () => {
    const meeting = byTitle(bundle.tasks, "اجتماع الفريق");
    expect(meeting).toMatchObject({
      key: "event:meeting1",
      projectKey: "calendar:fahad@example.com",
      dueDate: "2026-10-20",
      dueTime: "09:00",
      startDate: null,
      recurrence: null,
      done: false,
      notes: "جدول الأعمال\n• الميزانية\n• الخطة\n\nالمكان: مكتب الرياض",
    });
    // 21:30 UTC is half past midnight the next day in Riyadh.
    expect(byTitle(bundle.tasks, "مكالمة مع المورّد")).toMatchObject({ dueDate: "2026-10-17", dueTime: "00:30" });
    // 19:00 in London (BST) is 21:00 in Riyadh.
    expect(byTitle(bundle.tasks, "عشاء العائلة")).toMatchObject({ dueDate: "2026-10-18", dueTime: "21:00" });
  });

  it("spans multi-day all-day events from their first to their last day", () => {
    expect(byTitle(bundle.tasks, "إجازة")).toMatchObject({ startDate: "2026-10-25", dueDate: "2026-10-27", dueTime: null });
    expect(byTitle(bundle.tasks, "تسليم المشروع")).toMatchObject({ startDate: null, dueDate: "2026-10-22", dueTime: null });
  });

  it("makes a series one repeating task, due on its next occurrence", () => {
    const gym = bundle.tasks.filter((t) => t.title === "النادي");
    expect(gym).toHaveLength(1);
    expect(gym[0]).toMatchObject({ key: "event:gym", dueDate: "2026-10-15", dueTime: "18:00", recurrence: "FREQ=WEEKLY", notes: "أحضر المنشفة" });
    // COUNT=3 from the 14th: the 15th is next, with two occurrences left.
    expect(byTitle(bundle.tasks, "دورة")).toMatchObject({ key: "event:course", dueDate: "2026-10-15", recurrence: "FREQ=DAILY;COUNT=2" });
  });

  it("expands a series Zimam cannot repeat into its occurrences in the window", () => {
    // «The first Sunday» and a series with a cancelled occurrence.
    const council = bundle.tasks.filter((t) => t.title === "مجلس الحي");
    expect(council.map((t) => [t.key, t.dueDate, t.recurrence])).toEqual([
      ["event:council_20261101", "2026-11-01", null],
      ["event:council_20261206", "2026-12-06", null],
    ]);
    const visits = bundle.tasks.filter((t) => t.title === "زيارة الوالدة");
    expect(visits.map((t) => t.dueDate)).toEqual(["2026-10-17", "2026-10-31"]);
  });

  it("skips cancelled events, working locations and untitled events, and says so in Arabic", () => {
    expect(bundle.tasks.some((t) => t.title === "ملغى" || t.title === "Office")).toBe(false);
    expect(bundle.warnings).toEqual([
      "تقاويم العطل وأعياد الميلاد لم تُنقل: ١",
      "مهام بلا عنوان تُركت: ١",
      "مواعيد متكررة لا يعبّر عنها تكرار زمام، فنُقلت مرّاتها في المدة مهاماً منفصلة: ٢",
    ]);
    expect(bundle.tasks).toHaveLength(11);
  });
});

describe("Microsoft To Do", () => {
  const bundle = mapMicrosoftTodo(JSON.parse(microsoftTodoJson) as MicrosoftTodoData, RIYADH);

  it("maps lists, with «Tasks» as the inbox and flagged emails skipped", () => {
    expect(bundle.projects.map((p) => p.name)).toEqual(["البيت"]);
    expect(bundle.warnings).toContain("قائمة الرسائل المعلَّمة في Outlook لم تُنقل لأنها رسائل لا مهام: ١");
    expect(bundle.warnings).toContain("مهام بلا عنوان تُركت: ١");
  });

  it("maps importance, due day, reminder, categories and checklist steps", () => {
    const gift = byTitle(bundle.tasks, "شراء هدية");
    expect(gift).toMatchObject({
      key: "task:task-gift",
      projectKey: null,
      priority: 3,
      notes: "لأخي",
      tags: ["عائلة"],
      // Local midnight of the 20th in Riyadh, written in UTC.
      dueDate: "2026-10-20",
      dueTime: null,
      reminders: [{ key: "task:task-gift/reminder", at: "2026-10-20T09:00:00+03:00" }],
    });
    expect(byTitle(bundle.tasks, "اختيار الهدية")).toMatchObject({ parentKey: "task:task-gift", done: true, completedAt: Date.parse("2026-10-10T08:00:00Z") });
    expect(byTitle(bundle.tasks, "تغليفها")).toMatchObject({ parentKey: "task:task-gift", done: false });
  });

  it("maps recurrence when Zimam can repeat it, and keeps it as a note otherwise", () => {
    expect(byTitle(bundle.tasks, "تنظيف المكيف")).toMatchObject({ dueDate: "2026-10-17", recurrence: "FREQ=WEEKLY;INTERVAL=2" });
    const rent = byTitle(bundle.tasks, "دفع الإيجار");
    // Kept as text, so it does not repeat in Zimam, and its reminder stays.
    expect(rent).toMatchObject({ dueDate: "2026-11-02", recurrence: null, reminders: [{ key: "task:task-rent/reminder", at: "2026-11-02T09:00:00+03:00" }] });
    expect(rent.notes).toMatch(/^التكرار في Microsoft To Do: relativeMonthly/);
    expect(bundle.warnings).toContain("مهام لم يُفهم تكرارها، فحُفظ نصه في ملاحظاتها: ١");
    expect(todoRecurrence({ pattern: { type: "absoluteMonthly", dayOfMonth: 2 }, range: { type: "numbered", numberOfOccurrences: 6 } }, "2026-11-02")).toBe("FREQ=MONTHLY;COUNT=6");
    expect(todoRecurrence({ pattern: { type: "daily", interval: 3 }, range: { type: "endDate", endDate: "2026-12-31" } }, "2026-11-02")).toBe("FREQ=DAILY;INTERVAL=3;UNTIL=20261231");
  });

  it("brings completed tasks in done, with their time and HTML body as text", () => {
    expect(byTitle(bundle.tasks, "تجديد الاشتراك")).toMatchObject({
      done: true,
      completedAt: Date.parse("2026-10-01T10:00:00Z"),
      priority: 1,
      notes: "رقم العميل: ٤٥",
      startDate: "2026-09-28",
      dueDate: "2026-09-30",
    });
  });
});

describe("Notion", () => {
  const data = JSON.parse(notionJson) as NotionData;
  const bundle = mapNotion(data, RIYADH);

  it("finds the title, date, status, priority, tags, notes and parent properties", () => {
    const mapping = notionMapping(data.databases[0]!.database)!;
    expect(mapping).toMatchObject({ title: "المهمة", date: "الموعد", priority: "الأولوية", tags: "الوسوم", notes: "ملاحظات", parent: "Parent item" });
    expect(mapping.done).toMatchObject({ name: "الحالة", type: "status" });
    expect([...mapping.done!.doneIds]).toEqual(["s3"]);
    expect(notionMapping(data.databases[1]!.database)!.done).toMatchObject({ name: "Bought", type: "checkbox" });
  });

  it("maps pages to tasks, a date range to a start and due day", () => {
    expect(bundle.projects.map((p) => p.name)).toEqual(["مهام العمل", "Shopping"]);
    expect(byTitle(bundle.tasks, "إعداد العرض")).toMatchObject({
      key: "page:page-deck",
      startDate: "2026-10-18",
      dueDate: "2026-10-20",
      dueTime: null,
      priority: 3,
      tags: ["عمل", "عميل"],
      notes: "للعميل الجديد",
      done: false,
    });
    expect(byTitle(bundle.tasks, "مراجعة الشرائح")).toMatchObject({ parentKey: "page:page-deck", dueDate: "2026-10-19", dueTime: "14:00", done: true });
    // A wall clock with its own zone: 09:00 in London is 11:00 in Riyadh.
    expect(byTitle(bundle.tasks, "مكالمة لندن")).toMatchObject({ dueDate: "2026-10-21", dueTime: "11:00", priority: 2, done: false });
    expect(byTitle(bundle.tasks, "حليب")).toMatchObject({ done: true, priority: 3 });
    expect(byTitle(bundle.tasks, "خبز")).toMatchObject({ done: false, priority: 1 });
  });

  it("names what it left behind", () => {
    expect(bundle.tasks.some((t) => t.title === "مهمة محذوفة")).toBe(false);
    expect(bundle.warnings).toEqual([
      "عناصر مؤرشفة أو في سلة المحذوفات تُركت: ١",
      "مهام بلا عنوان تُركت: ١",
      "خصائص من «مهام العمل» لم تُنقل: المسؤول",
    ]);
  });
});

describe("Trello", () => {
  const bundle = mapTrello(JSON.parse(trelloJson) as TrelloData, RIYADH);

  it("maps boards to kanban projects and open lists to sections in order", () => {
    expect(bundle.projects.map((p) => [p.name, p.view])).toEqual([["تجديد البيت", "kanban"]]);
    expect(bundle.sections.map((s) => s.name)).toEqual(["للعمل", "تم"]);
  });

  it("maps cards with due time, start day, labels, completion and checklist items", () => {
    expect(byTitle(bundle.tasks, "دهان الغرفة")).toMatchObject({
      key: "card:card-paint",
      sectionKey: "list:list-todo",
      dueDate: "2026-10-20",
      dueTime: "09:00",
      startDate: "2026-10-18",
      tags: ["عاجل"],
      notes: "لون أبيض مطفي",
      done: false,
    });
    expect(byTitle(bundle.tasks, "شراء الأدوات")).toMatchObject({ sectionKey: "list:list-done", done: true });
    const items = bundle.tasks.filter((t) => t.parentKey === "card:card-paint");
    expect(items.map((t) => [t.title, t.done])).toEqual([
      ["شراء الطلاء", true],
      ["تغطية الأثاث", false],
    ]);
    expect(bundle.warnings).toEqual(["عناصر مؤرشفة أو في سلة المحذوفات تُركت: ٢"]);
  });

  it("carries the API key with the token in one credential", () => {
    expect(parseTrelloCredential(trelloCredential("key123", "ATTAtoken"))).toEqual({ apiKey: "key123", token: "ATTAtoken" });
    expect(parseTrelloCredential("no-separator")).toBeNull();
  });
});

describe("Asana", () => {
  const bundle = mapAsana(JSON.parse(asanaJson) as AsanaData, RIYADH);

  it("maps projects with their view, and sections without Asana's unnamed one", () => {
    expect(bundle.projects.map((p) => [p.name, p.view])).toEqual([
      ["إطلاق الموقع", "kanban"],
      ["شخصي", "list"],
    ]);
    expect(bundle.sections.map((s) => s.name)).toEqual(["التصميم", "التطوير"]);
    expect(byTitle(bundle.tasks, "مهمة بلا قسم").sectionKey).toBeNull();
  });

  it("maps due days and times, start days, completion, tags and subtasks", () => {
    expect(byTitle(bundle.tasks, "تصميم الصفحة الرئيسية")).toMatchObject({
      sectionKey: "section:2101",
      dueDate: "2026-10-22",
      dueTime: null,
      startDate: "2026-10-19",
      tags: ["تصميم"],
      notes: "نسخة الجوال أولاً",
    });
    expect(byTitle(bundle.tasks, "ربط الدفع")).toMatchObject({ dueDate: "2026-10-25", dueTime: "10:00", done: true, completedAt: Date.parse("2026-10-12T10:00:00Z") });
    expect(byTitle(bundle.tasks, "الأيقونات")).toMatchObject({ parentKey: "task:3001", projectKey: "project:1201", sectionKey: "section:2101" });
  });

  it("imports a task in two projects once, and skips archived projects", () => {
    expect(bundle.tasks.filter((t) => t.title === "قراءة كتاب")).toHaveLength(1);
    expect(byTitle(bundle.tasks, "قراءة كتاب").projectKey).toBe("project:1201");
    expect(bundle.warnings).toEqual(["مهام بلا عنوان تُركت: ١", "عناصر مؤرشفة أو في سلة المحذوفات تُركت: ١"]);
  });
});

describe("TickTick Open API", () => {
  const bundle = mapTickTickApi(JSON.parse(tickTickApiJson) as TickTickData, RIYADH);

  it("uses the CSV backup's keys, so either import updates the other", () => {
    const work = derivedKey("ticktick", "list", "العمل");
    expect(bundle.projects.map((p) => [p.key, p.name, p.view])).toEqual([[work, "العمل", "kanban"]]);
    expect(bundle.sections.map((s) => [s.key, s.name])).toEqual([
      [derivedKey(work, "column", "للعمل"), "للعمل"],
      [derivedKey(work, "column", "قيد العمل"), "قيد العمل"],
    ]);
    expect(byTitle(bundle.tasks, "كتابة التقرير").key).toBe("task:t-report");
  });

  it("maps dates in the task's zone, recurrence, reminders, checklist items and completion", () => {
    expect(byTitle(bundle.tasks, "ورد الصباح")).toMatchObject({ projectKey: null, dueDate: "2026-10-14", dueTime: "05:30", recurrence: "FREQ=DAILY" });
    expect(byTitle(bundle.tasks, "كتابة التقرير")).toMatchObject({
      priority: 3,
      notes: "للإدارة",
      tags: ["عمل"],
      dueDate: "2026-10-20",
      dueTime: null,
      startDate: "2026-10-18",
      sectionKey: derivedKey(derivedKey("ticktick", "list", "العمل"), "column", "قيد العمل"),
      reminders: [{ key: "task:t-report/reminder:TRIGGER:P0DT9H0M0S", at: "2026-10-20T09:00:00+03:00" }],
    });
    expect(byTitle(bundle.tasks, "المقدمة")).toMatchObject({ parentKey: "task:t-report", done: true });
    expect(byTitle(bundle.tasks, "الخاتمة")).toMatchObject({ parentKey: "task:t-report", done: false });
    expect(byTitle(bundle.tasks, "إرسال الفاتورة")).toMatchObject({ done: true, priority: 2, completedAt: Date.parse("2026-10-10T08:00:00Z") });
    const monthly = byTitle(bundle.tasks, "اجتماع شهري");
    expect(monthly).toMatchObject({ recurrence: null, dueDate: "2026-10-12", dueTime: "08:00" });
    expect(monthly.notes).toBe("التكرار في TickTick: RRULE:FREQ=MONTHLY;BYDAY=2MO");
    expect(bundle.warnings).toEqual(["ملاحظات ليست مهاماً تُركت: ١", "عناصر مؤرشفة أو في سلة المحذوفات تُركت: ١", "مهام لم يُفهم تكرارها، فحُفظ نصه في ملاحظاتها: ١"]);
  });

  it("flattens for the importer with parents first", () => {
    const items = flatten(bundle);
    const order = items.filter((i) => i.entity === "task").map((i) => i.record.key);
    expect(order.indexOf("task:t-report")).toBeLessThan(order.indexOf("item:i-intro"));
    expect(items.filter((i) => i.entity === "reminder")).toHaveLength(2);
  });
});
