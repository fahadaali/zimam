import { foldForSearch } from "../../data/arabic";
import { csvRecords, headerKey, parseCsv } from "../csv";
import { parseDateText, parseTime } from "../dates";
import {
  addNote,
  fitName,
  fitTask,
  type ImportBundle,
  ImportError,
  type ImportedProject,
  type ImportedSection,
  type ImportedTask,
  LIMITS,
  Warnings,
} from "../model";
import { derivedKey, type FileSource, Occurrences, type ParseContext } from "../source";

/** Column names people use, in English and Arabic; compared after `headerKey` folding. */
const COLUMNS = {
  title: ["title", "task", "task name", "name", "content", "subject", "العنوان", "المهمة", "اسم المهمة", "مهمة", "المهام"],
  notes: ["notes", "note", "description", "details", "body", "الملاحظات", "ملاحظات", "ملاحظة", "الوصف", "التفاصيل"],
  due: ["due", "due date", "date", "deadline", "الموعد", "التاريخ", "تاريخ الاستحقاق", "موعد التسليم", "الاستحقاق", "تاريخ"],
  time: ["time", "due time", "الوقت", "الساعة"],
  project: ["project", "list", "project name", "المشروع", "القائمة", "اسم المشروع"],
  section: ["section", "column", "القسم", "العمود"],
  priority: ["priority", "importance", "الأولوية", "الأهمية"],
  status: ["status", "done", "completed", "complete", "state", "الحالة", "منجزة", "مكتملة", "تم"],
  tags: ["tags", "labels", "tag", "label", "الوسوم", "الوسم", "التصنيفات"],
} as const;

type Column = keyof typeof COLUMNS;

const ALIASES = new Map<string, Column>(
  (Object.entries(COLUMNS) as [Column, readonly string[]][]).flatMap(([column, names]) => names.map((n) => [headerKey(n), column] as const)),
);

const PRIORITY_WORDS = new Map<string, number>(
  (
    [
      [3, ["3", "high", "urgent", "p1", "!!!", "عالية", "عالي", "مرتفعة", "عاجل", "عاجلة", "مهم جدا"]],
      [2, ["2", "medium", "p2", "!!", "متوسطة", "متوسط"]],
      [1, ["1", "low", "p3", "!", "منخفضة", "منخفض"]],
      [0, ["0", "none", "p4", "بلا", "لا يوجد", "عادية", "عادي"]],
    ] as const
  ).flatMap(([level, words]) => words.map((w) => [foldForSearch(w), level] as const)),
);

const DONE_WORDS = new Set(
  ["done", "completed", "complete", "closed", "yes", "y", "true", "x", "✓", "✔", "1", "منجزة", "منجز", "مكتملة", "مكتمل", "تم", "تمت", "نعم", "منتهية"].map(foldForSearch),
);

/** Zimam's level 0–3 from a priority cell; anything not understood is "none". */
export function genericPriority(value: string): number {
  return PRIORITY_WORDS.get(foldForSearch(value)) ?? 0;
}

const NO_TITLE = new ImportError(
  "invalid_file",
  "لم نجد عمود عنوان المهمة. اجعل الصف الأول أسماء الأعمدة، وفيه عمود «العنوان» (أو title)، ثم أعد رفع الملف.",
);

/**
 * Any CSV with a header row. Columns are found by name in Arabic or English (see
 * `COLUMNS`): title (required), notes, due date, time, project, section, priority,
 * status, tags. The delimiter (comma, semicolon or tab) is detected.
 *
 * - No project → the inbox. A project's section → a section; ignored in the inbox.
 * - Dates: see `parseDateText` (ISO, day-first numbers, month names, Hijri by year).
 *   A date that cannot be read is kept in the notes.
 * - Priority: high / medium / low or عالية / متوسطة / منخفضة, p1–p4, or 0–3.
 * - Status: done, yes, x, منجزة, تم… → done. Everything else stays open.
 * - Tags: separated by commas (, or ،) or semicolons.
 */
export function parseGenericCsv(text: string, ctx: ParseContext): ImportBundle {
  const { header, records } = csvRecords(parseCsv(text));
  const columnOf = new Map<Column, string>();
  for (const name of header) {
    const column = ALIASES.get(name);
    if (column && !columnOf.has(column)) columnOf.set(column, name);
  }
  if (!columnOf.has("title")) throw NO_TITLE;
  const warnings = new Warnings();
  const projects = new Map<string, ImportedProject>();
  const sections = new Map<string, ImportedSection>();
  const tasks: ImportedTask[] = [];
  const seen = new Occurrences();

  for (const record of records) {
    const get = (column: Column) => {
      const name = columnOf.get(column);
      return name ? (record.get(name) ?? "") : "";
    };
    const title = get("title");
    if (!title) {
      warnings.add("untitledSkipped");
      continue;
    }
    const projectName = fitName(get("project"), LIMITS.projectName);
    let projectKey: string | null = null;
    if (projectName) {
      projectKey = derivedKey("csv", "project", projectName);
      if (!projects.has(projectKey)) {
        projects.set(projectKey, { key: projectKey, name: projectName, kind: "project", parentKey: null, view: "list", sortOrder: projects.size, archived: false });
      }
    }
    const sectionName = fitName(get("section"), LIMITS.sectionName);
    let sectionKey: string | null = null;
    if (sectionName && projectKey) {
      sectionKey = derivedKey(projectKey, "section", sectionName);
      if (!sections.has(sectionKey)) sections.set(sectionKey, { key: sectionKey, projectKey, name: sectionName, sortOrder: sections.size });
    } else if (sectionName) {
      warnings.add("sectionsDropped");
    }

    let notes: string | null = get("notes") || null;
    let dueDate: string | null = null;
    let dueTime: string | null = null;
    const dueText = get("due");
    if (dueText) {
      const parsed = parseDateText(dueText, ctx.timeZone);
      if (parsed) {
        dueDate = parsed.date;
        dueTime = parsed.time;
      } else {
        notes = addNote(notes, `الموعد في الملف: ${dueText}`);
        warnings.add("dateKept");
      }
    }
    const timeText = get("time");
    if (timeText && dueDate) {
      const time = parseTime(timeText);
      if (time) dueTime = time;
      else notes = addNote(notes, `الوقت في الملف: ${timeText}`);
    }

    const done = DONE_WORDS.has(foldForSearch(get("status")));
    const n = seen.next(projectKey, sectionKey, title);
    tasks.push({
      key: derivedKey("csv", projectKey, sectionKey, "task", title, n),
      projectKey,
      sectionKey,
      parentKey: null,
      title,
      notes,
      priority: genericPriority(get("priority")),
      tags: get("tags")
        .split(/[,،;؛]/)
        .map((t) => t.trim().replace(/^#/, ""))
        .filter(Boolean),
      dueDate,
      dueTime,
      recurrence: null,
      done,
      completedAt: null,
      sortOrder: tasks.length,
      reminders: [],
    });
  }
  return { projects: [...projects.values()], sections: [...sections.values()], tasks: tasks.map(fitTask), warnings: warnings.list() };
}

export const genericCsv: FileSource = {
  id: "csv",
  label: "CSV",
  refSource: "csv",
  input: "file",
  extensions: [".csv", ".tsv", ".txt"],
  parse: parseGenericCsv,
};
