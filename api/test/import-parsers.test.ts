import { describe, expect, it } from "vitest";
import { flatten } from "../src/imports/apply";
import { decodeText, detectDelimiter, parseCsv } from "../src/imports/csv";
import { durationMs, isoWithOffset, localToInstant, parseDateText, parseTime, recurrenceFromText } from "../src/imports/dates";
import { emptyBundle, fitTask, ImportError, type ImportedTask, orderTasks } from "../src/imports/model";
import { genericPriority, parseGenericCsv } from "../src/imports/sources/generic-csv";
import { parseGoogleTasks } from "../src/imports/sources/google-tasks";
import { parseTickTickCsv, tickTickPriority } from "../src/imports/sources/ticktick";
import { mapTodoist, parseTodoistCsv, splitLabels, type TodoistData, todoistPriority } from "../src/imports/sources/todoist";
import genericArabic from "./fixtures/imports/generic-arabic.csv?raw";
import googleTasksJson from "./fixtures/imports/google-tasks.json?raw";
import tickTickBackup from "./fixtures/imports/ticktick-backup.csv?raw";
import todoistApiJson from "./fixtures/imports/todoist-api.json?raw";
import todoistTemplate from "./fixtures/imports/todoist-template.csv?raw";

const RIYADH = { timeZone: "Asia/Riyadh", fileName: null };
const byTitle = (tasks: ImportedTask[], title: string) => {
  const task = tasks.find((t) => t.title === title);
  if (!task) throw new Error(`no task «${title}» in ${tasks.map((t) => t.title).join(" | ")}`);
  return task;
};

describe("CSV", () => {
  it("handles a BOM, quoted delimiters, doubled quotes, line breaks and CRLF", () => {
    const text = '﻿title,notes\r\n"شراء، خبز","سطر ""أول""\r\nسطر ثانٍ"\r\nبلا ملاحظات,\r\n,\r\n';
    expect(parseCsv(text)).toEqual([
      ["title", "notes"],
      ["شراء، خبز", 'سطر "أول"\r\nسطر ثانٍ'],
      ["بلا ملاحظات", ""],
    ]);
  });

  it("detects semicolons and tabs, ignoring delimiters inside quotes", () => {
    expect(detectDelimiter('"a,b,c";d;e\n1;2;3')).toBe(";");
    expect(detectDelimiter("a\tb\tc\n")).toBe("\t");
    expect(parseCsv("title;due\nمهمة;2026-10-20\n")).toEqual([["title", "due"], ["مهمة", "2026-10-20"]]);
  });

  it("decodes UTF-8 with or without BOM, UTF-16 and Windows-1256", () => {
    const utf8 = new TextEncoder().encode("﻿العنوان");
    expect(decodeText(utf8)).toBe("العنوان");
    const utf16 = new Uint8Array([0xff, 0xfe, 0x27, 0x06, 0x44, 0x06]);
    expect(decodeText(utf16)).toBe("ال");
    // «العنوان» as Excel on Arabic Windows saves it.
    expect(decodeText(new Uint8Array([0xc7, 0xe1, 0xda, 0xe4, 0xe6, 0xc7, 0xe4]))).toBe("العنوان");
  });
});

describe("Dates", () => {
  it("reads ISO, day-first, month names, Arabic digits and Hijri", () => {
    const tz = "Asia/Riyadh";
    expect(parseDateText("2026-10-20", tz)).toEqual({ date: "2026-10-20", time: null });
    expect(parseDateText("2026-10-20 14:30", tz)).toEqual({ date: "2026-10-20", time: "14:30" });
    expect(parseDateText("20/10/2026", tz)).toEqual({ date: "2026-10-20", time: null });
    expect(parseDateText("05/10/2026", tz)).toEqual({ date: "2026-10-05", time: null });
    expect(parseDateText("10/20/2026", tz)).toEqual({ date: "2026-10-20", time: null });
    expect(parseDateText("Oct 20 2026", tz)).toEqual({ date: "2026-10-20", time: null });
    expect(parseDateText("October 20, 2026 at 9:15 PM", tz)).toEqual({ date: "2026-10-20", time: "21:15" });
    expect(parseDateText("٢٠ أكتوبر ٢٠٢٦", tz)).toEqual({ date: "2026-10-20", time: null });
    expect(parseDateText("٢٠٢٦/١٠/٢٠ ٢:٣٠ م", tz)).toEqual({ date: "2026-10-20", time: "14:30" });
    expect(parseDateText("١٤٤٨/٠٥/٠١ هـ", tz)).toEqual({ date: "2026-10-12", time: null });
    expect(parseDateText("1/5/1448", tz)).toEqual({ date: "2026-10-12", time: null });
  });

  it("converts instants to the user's zone and keeps floating times as written", () => {
    expect(parseDateText("2026-10-19T21:00:00Z", "Asia/Riyadh")).toEqual({ date: "2026-10-20", time: "00:00" });
    expect(parseDateText("2026-10-19T21:00:00+0000", "America/New_York")).toEqual({ date: "2026-10-19", time: "17:00" });
    expect(parseDateText("2026-10-20T09:00:00", "America/New_York")).toEqual({ date: "2026-10-20", time: "09:00" });
  });

  it("leaves relative or impossible dates alone", () => {
    for (const text of ["tomorrow", "next week", "every day", "31/02/2026", "2026-13-01", "", "غداً"]) {
      expect(parseDateText(text, "Asia/Riyadh")).toBeNull();
    }
  });

  it("parses times and builds instants with offsets", () => {
    expect(parseTime("9am")).toBe("09:00");
    expect(parseTime("12:05 ص")).toBe("00:05");
    expect(parseTime("25:00")).toBeNull();
    const at = localToInstant("2026-10-20", "09:00", "Asia/Riyadh");
    expect(new Date(at).toISOString()).toBe("2026-10-20T06:00:00.000Z");
    expect(isoWithOffset(at, "Asia/Riyadh")).toBe("2026-10-20T09:00:00+03:00");
    // Daylight saving: New York is UTC-4 in October and UTC-5 in December.
    expect(isoWithOffset(localToInstant("2026-12-01", "09:00", "America/New_York"), "America/New_York")).toBe("2026-12-01T09:00:00-05:00");
  });

  it("maps simple recurrence phrases and rejects the rest", () => {
    expect(recurrenceFromText("every day")).toBe("FREQ=DAILY");
    expect(recurrenceFromText("every day at 5:30am")).toBe("FREQ=DAILY");
    expect(recurrenceFromText("every 2 weeks")).toBe("FREQ=WEEKLY;INTERVAL=2");
    expect(recurrenceFromText("every monday, thursday")).toBe("FREQ=WEEKLY;BYDAY=MO,TH");
    expect(recurrenceFromText("every weekday")).toBe("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR");
    expect(recurrenceFromText("every other thursday")).toBeNull();
    expect(recurrenceFromText("every! 3 days")).toBeNull();
    expect(durationMs("-PT15M")).toBe(-15 * 60_000);
    expect(durationMs("P0DT9H0M0S")).toBe(9 * 3_600_000);
    expect(durationMs("P")).toBeNull();
  });
});

describe("Todoist CSV template", () => {
  const bundle = parseTodoistCsv(todoistTemplate, { timeZone: "Asia/Riyadh", fileName: "زواج فهد.csv" });

  it("names the project after the file and keeps sections in order", () => {
    expect(bundle.projects).toMatchObject([{ name: "زواج فهد", kind: "project" }]);
    expect(bundle.sections.map((s) => s.name)).toEqual(["التحضير", "الدعوات"]);
  });

  it("maps tasks, subtasks, notes, labels and priorities", () => {
    const [prep, invites] = bundle.sections;
    const hall = byTitle(bundle.tasks, "حجز القاعة");
    expect(hall).toMatchObject({
      sectionKey: prep!.key,
      parentKey: null,
      notes: "الاتصال بثلاث قاعات، ومقارنة الأسعار",
      priority: 3,
      tags: ["زواج"],
      dueDate: "2026-10-20",
      dueTime: null,
      done: false,
    });
    expect(byTitle(bundle.tasks, "مقارنة الأسعار")).toMatchObject({
      parentKey: hall.key,
      priority: 0,
      notes: 'القاعة الأولى أرخص، لكن "المواقف" قليلة',
    });
    expect(byTitle(bundle.tasks, "شراء البشت، والعقال")).toMatchObject({ priority: 2, dueDate: "2026-10-25", dueTime: "17:30" });
    expect(byTitle(bundle.tasks, "إرسال الدعوات")).toMatchObject({
      sectionKey: invites!.key,
      priority: 1,
      dueDate: null,
      recurrence: null,
      notes: "القائمة:\n- العائلة\n- الأصدقاء\n\nالتكرار في Todoist: every day",
    });
    // "tomorrow" is relative: kept as a note; the deadline becomes the date.
    expect(byTitle(bundle.tasks, "Confirm the caterer")).toMatchObject({
      dueDate: "2026-10-30",
      notes: "الموعد في Todoist: tomorrow",
    });
    expect(bundle.warnings).toEqual([
      "مهام لم يُفهم تكرارها، فحُفظ نصه في ملاحظاتها: ١",
      "مواعيد نسبية أو غير مفهومة، حُفظ نصها في ملاحظات مهامها: ١",
    ]);
  });

  it("gives the same keys for the same file, and different keys to same-named tasks", () => {
    const again = parseTodoistCsv(todoistTemplate, { timeZone: "Asia/Riyadh", fileName: "زواج فهد.csv" });
    expect(again.tasks.map((t) => t.key)).toEqual(bundle.tasks.map((t) => t.key));
    const twice = parseTodoistCsv("TYPE,CONTENT,PRIORITY,INDENT\ntask,اتصال,1,1\ntask,اتصال,1,1\n", RIYADH);
    expect(new Set(twice.tasks.map((t) => t.key)).size).toBe(2);
  });

  it("rejects a file that is not a Todoist template", () => {
    expect(() => parseTodoistCsv("name,email\nفهد,a@b.c\n", RIYADH)).toThrow(ImportError);
  });

  it("maps Todoist priorities and inline labels", () => {
    expect([4, 3, 2, 1, undefined].map(todoistPriority)).toEqual([3, 2, 1, 0, 0]);
    expect(splitLabels("Email a@b.com @work @عاجل")).toEqual({ title: "Email a@b.com", labels: ["work", "عاجل"] });
  });
});

describe("Todoist API", () => {
  const bundle = mapTodoist(JSON.parse(todoistApiJson) as TodoistData, RIYADH);

  it("maps the inbox to Zimam's inbox and a parent with no tasks to a folder", () => {
    expect(bundle.projects.map((p) => [p.key, p.name, p.kind, p.parentKey, p.view])).toEqual([
      ["project:2203306142", "العمل", "folder", null, "list"],
      ["project:2203306143", "مشروع الموقع", "project", "project:2203306142", "kanban"],
      ["project:2203306144", "المنزل", "project", null, "list"],
    ]);
    expect(bundle.sections.map((s) => s.name)).toEqual(["للعمل", "قيد التنفيذ"]);
    expect(byTitle(bundle.tasks, "ورد الصباح")).toMatchObject({ projectKey: null, sectionKey: null });
    expect(bundle.warnings).toContain("أقسام في صندوق الوارد لا تُنقل، فبقيت مهامها في الصندوق بلا قسم: ١");
  });

  it("maps due dates, recurrence, deadlines, labels and priorities", () => {
    expect(byTitle(bundle.tasks, "تصميم الصفحة الرئيسية")).toMatchObject({
      key: "task:7498225981",
      sectionKey: "section:7026",
      priority: 3,
      tags: ["تصميم"],
      dueDate: "2026-10-20",
      dueTime: null,
      notes: "ألوان الهوية، والخط",
    });
    expect(byTitle(bundle.tasks, "اختيار الخط")).toMatchObject({ parentKey: "task:7498225981", priority: 2, dueDate: "2026-10-28" });
    // A UTC datetime becomes the user's wall clock; the phrase becomes an RRULE.
    expect(byTitle(bundle.tasks, "ورد الصباح")).toMatchObject({ dueDate: "2026-10-14", dueTime: "05:30", recurrence: "FREQ=DAILY", priority: 0 });
    expect(byTitle(bundle.tasks, "سقي النباتات")).toMatchObject({
      dueDate: "2026-10-16",
      recurrence: null,
      notes: "التكرار في Todoist: every other thursday",
      priority: 1,
    });
  });

  it("puts parents before subtasks", () => {
    const keys = bundle.tasks.map((t) => t.key);
    expect(keys.indexOf("task:7498225981")).toBeLessThan(keys.indexOf("task:7498225982"));
  });
});

describe("TickTick backup", () => {
  const bundle = parseTickTickCsv(tickTickBackup, RIYADH);

  it("finds the header after the metadata lines and maps folders, lists and columns", () => {
    expect(bundle.projects.map((p) => [p.name, p.kind, p.view])).toEqual([
      ["العمل", "folder", "list"],
      ["مشروع الموقع", "project", "kanban"],
      ["المنزل", "project", "list"],
    ]);
    expect(bundle.projects[1]!.parentKey).toBe(bundle.projects[0]!.key);
    expect(bundle.sections).toMatchObject([{ name: "قيد التنفيذ", projectKey: bundle.projects[1]!.key }]);
  });

  it("reads all-day dates in the task's zone and turns reminders into instants", () => {
    expect(byTitle(bundle.tasks, "تصميم الصفحة الرئيسية")).toMatchObject({
      key: "task:6710a1b2c3d4e5f600000001",
      dueDate: "2026-10-20",
      dueTime: null,
      priority: 3,
      tags: ["تصميم", "عاجل"],
      notes: "ألوان الهوية، والخط",
      reminders: [{ at: "2026-10-20T09:00:00+03:00" }],
    });
    expect(byTitle(bundle.tasks, "اختيار الخط")).toMatchObject({ parentKey: "task:6710a1b2c3d4e5f600000001", priority: 2 });
    const contract = byTitle(bundle.tasks, "مراجعة العقد");
    expect(contract).toMatchObject({ projectKey: null, dueDate: "2026-10-21", dueTime: "09:30", priority: 1 });
    expect(contract.reminders.map((r) => r.at)).toEqual(["2026-10-21T09:15:00+03:00", "2026-10-21T09:30:00+03:00"]);
  });

  it("keeps recurrence, marks completed tasks done, and skips notes", () => {
    expect(byTitle(bundle.tasks, "ورد الصباح")).toMatchObject({ recurrence: "FREQ=DAILY", dueDate: "2026-10-14", reminders: [] });
    expect(byTitle(bundle.tasks, "تجديد الإقامة")).toMatchObject({
      done: true,
      completedAt: Date.parse("2026-09-29T12:15:00Z"),
      dueDate: "2026-10-01",
    });
    expect(bundle.tasks.some((t) => t.title === "أفكار للمطبخ")).toBe(false);
    expect(bundle.warnings).toEqual([
      "تذكيرات لم تُنقل لأنها على مهام متكررة أو منجزة أو بلا موعد: ١",
      "ملاحظات ليست مهاماً تُركت: ١",
    ]);
  });

  it("maps TickTick priorities and rejects other CSV files", () => {
    expect(["0", "1", "3", "5"].map(tickTickPriority)).toEqual([0, 1, 2, 3]);
    expect(() => parseTickTickCsv(todoistTemplate, RIYADH)).toThrow(ImportError);
  });
});

describe("Google Tasks (Takeout)", () => {
  const bundle = parseGoogleTasks(googleTasksJson, RIYADH);

  it("maps lists to projects and keeps Google's order and subtasks", () => {
    expect(bundle.projects.map((p) => p.name)).toEqual(["مهامي", "Shopping"]);
    expect(bundle.tasks.map((t) => t.title)).toEqual(["تجديد رخصة القيادة", "تصوير الصورة الشخصية", "Pay electricity bill", "Dates (تمر)"]);
    expect(byTitle(bundle.tasks, "تصوير الصورة الشخصية").parentKey).toBe("task:dGFzay0x");
  });

  it("reads the due date as written and completed tasks as done", () => {
    expect(byTitle(bundle.tasks, "تجديد رخصة القيادة")).toMatchObject({ dueDate: "2026-10-22", notes: "من أبشر، قبل نهاية الشهر", done: false });
    expect(byTitle(bundle.tasks, "Pay electricity bill")).toMatchObject({ done: true, completedAt: Date.parse("2026-10-05T14:20:00Z"), dueDate: "2026-10-05" });
    expect(byTitle(bundle.tasks, "Dates (تمر)").notes).toBe("Order confirmation: https://mail.google.com/mail/#all/abc123");
    expect(bundle.warnings).toEqual(["مهام محذوفة في المصدر تُركت: ١", "مهام بلا عنوان تُركت: ١"]);
  });

  it("rejects other JSON and broken JSON", () => {
    expect(() => parseGoogleTasks('{"tasks": []}', RIYADH)).toThrow(ImportError);
    expect(() => parseGoogleTasks("{ not json", RIYADH)).toThrow(ImportError);
  });
});

describe("Generic CSV", () => {
  it("reads Arabic headers, Arabic digits, Hijri dates and quoted line breaks", () => {
    const bundle = parseGenericCsv(genericArabic, RIYADH);
    expect(bundle.projects.map((p) => p.name)).toEqual(["العمل"]);
    expect(bundle.sections.map((s) => s.name)).toEqual(["قيد المراجعة"]);
    expect(bundle.tasks.map((t) => t.title)).toEqual(["مراجعة العقد", "إرسال الفاتورة", "زيارة الوالدة", 'تجهيز "العرض" للاجتماع']);
    expect(bundle.tasks[0]).toMatchObject({
      projectKey: bundle.projects[0]!.key,
      sectionKey: bundle.sections[0]!.key,
      notes: "البند الرابع، والخامس",
      dueDate: "2026-10-20",
      dueTime: "14:30",
      priority: 3,
      tags: ["قانوني", "عاجل"],
      done: false,
    });
    expect(bundle.tasks[1]).toMatchObject({ dueDate: "2026-10-20", priority: 2, done: true, sectionKey: null });
    expect(bundle.tasks[2]).toMatchObject({ projectKey: null, dueDate: "2026-10-12" });
    expect(bundle.tasks[3]).toMatchObject({ dueDate: null, priority: 1, notes: "الموعد في الملف: next week" });
  });

  it("reads English headers with semicolons", () => {
    const bundle = parseGenericCsv("Title;Due Date;Project;Priority;Done\nBuy dates;2026-10-20T10:00:00Z;Home;p1;yes\n", RIYADH);
    expect(bundle.tasks[0]).toMatchObject({ title: "Buy dates", dueDate: "2026-10-20", dueTime: "13:00", priority: 3, done: true });
  });

  it("needs a title column", () => {
    expect(() => parseGenericCsv("a,b\n1,2\n", RIYADH)).toThrow(ImportError);
    expect(genericPriority("عالية")).toBe(3);
    expect(genericPriority("منخفضه")).toBe(1);
  });
});

describe("Bundle checks", () => {
  it("fits over-long titles into the notes without losing text", () => {
    const long = "م".repeat(600);
    const task = fitTask({ ...byTitle(parseGenericCsv("title\nx\n", RIYADH).tasks, "x"), title: long, tags: [" a ", "a", "b".repeat(60)] });
    expect(task.title).toHaveLength(500);
    expect(task.notes).toBe(long);
    expect(task.tags).toEqual(["a", "b".repeat(50)]);
  });

  it("breaks parent cycles and drops links to missing records", () => {
    const base = parseGenericCsv("title\nأ\nب\n", RIYADH).tasks;
    const [a, b] = base as [ImportedTask, ImportedTask];
    a.parentKey = b.key;
    b.parentKey = a.key;
    const ordered = orderTasks([a, b]);
    const [first, second] = ordered as [ImportedTask, ImportedTask];
    expect(first.parentKey).toBeNull();
    expect(second.parentKey).toBe(first.key);

    const bundle = emptyBundle();
    bundle.tasks.push({ ...a, key: "t1", projectKey: "missing", sectionKey: "missing", parentKey: "missing" });
    const { reminders: _, ...record } = a;
    expect(flatten(bundle)).toEqual([
      { entity: "task", record: { ...record, key: "t1", projectKey: null, sectionKey: null, parentKey: null } },
    ]);
  });
});
