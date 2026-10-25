import { csvRecords, parseCsv } from "../csv";
import { durationMs, isoWithOffset, isTimeZone, localToInstant, parseDateText } from "../dates";
import { zimamRule } from "../recurrence";
import {
  addNote,
  fitName,
  fitTask,
  type ImportBundle,
  ImportError,
  type ImportedProject,
  type ImportedReminder,
  type ImportedSection,
  type ImportedTask,
  LIMITS,
  orderTasks,
  Warnings,
} from "../model";
import { derivedKey, type FileSource, nativeKey, type ParseContext } from "../source";

/** TickTick: 0 none, 1 low, 3 medium, 5 high. */
export function tickTickPriority(value: string | undefined): number {
  const n = Number(value);
  return n >= 5 ? 3 : n >= 3 ? 2 : n >= 1 ? 1 : 0;
}

const INBOX_NAMES = new Set(["inbox", "صندوق الوارد", "الوارد"]);

const NOT_TICKTICK = new ImportError(
  "invalid_file",
  "هذا ليس ملف نسخة احتياطية من TickTick. في TickTick افتح «الإعدادات ← الحساب ← النسخ الاحتياطي» وصدّر ملف CSV.",
);

/** "true" / "Y" / "1". */
const truthy = (v: string | undefined) => /^(true|y|yes|1)$/i.test(v?.trim() ?? "");

/**
 * TickTick's CSV backup («النسخ الاحتياطي»). A few lines of metadata come before the
 * header row ("Folder Name","List Name","Title",...). Dates are instants
 * ("2026-10-19T21:00:00+0000"); they are read in the task's own Timezone column, which
 * gives the day and time the user saw in TickTick, or in the user's zone without one.
 *
 * - Folder Name → folder; List Name → project («Inbox» → the inbox); Column Name → section.
 * - Status 0 open; 1 completed and 2 archived → done; -1 (won't do) → done, with a note.
 * - Repeat ("RRULE:FREQ=WEEKLY;BYDAY=TH") → recurrence when it is a plain RRULE, else a note.
 * - Reminder ("TRIGGER:-PT15M", relative to the due time, or to midnight for all-day
 *   tasks) → time reminders, on open tasks that do not repeat.
 * - Kind NOTE (TickTick notes, not tasks) is skipped. Checklist items stay in the notes.
 */
export function parseTickTickCsv(text: string, ctx: ParseContext): ImportBundle {
  const rows = parseCsv(text);
  const headerAt = rows.findIndex((r) => r.some((c) => c.trim().toLowerCase() === "list name") && r.some((c) => c.trim().toLowerCase() === "title"));
  if (headerAt < 0) throw NOT_TICKTICK;
  const { records } = csvRecords(rows.slice(headerAt));
  const warnings = new Warnings();
  const projects = new Map<string, ImportedProject>();
  const sections = new Map<string, ImportedSection>();
  const tasks: ImportedTask[] = [];

  const folderFor = (name: string): string | null => {
    const folder = fitName(name, LIMITS.projectName);
    if (!folder) return null;
    const key = derivedKey("ticktick", "folder", folder);
    if (!projects.has(key)) {
      projects.set(key, { key, name: folder, kind: "folder", parentKey: null, view: "list", sortOrder: projects.size, archived: false });
    }
    return key;
  };

  for (const r of records) {
    const get = (column: string) => r.get(column) ?? "";
    if (get("kind").toUpperCase() === "NOTE") {
      warnings.add("notesSkipped");
      continue;
    }
    const title = get("title");
    if (!title) {
      warnings.add("untitledSkipped");
      continue;
    }
    const listName = fitName(get("list name"), LIMITS.projectName);
    let projectKey: string | null = null;
    if (listName && !INBOX_NAMES.has(listName.toLowerCase())) {
      projectKey = derivedKey("ticktick", "list", listName);
      if (!projects.has(projectKey)) {
        const viewMode = get("view mode").toLowerCase();
        projects.set(projectKey, {
          key: projectKey,
          name: listName,
          kind: "project",
          parentKey: folderFor(get("folder name")),
          view: viewMode === "kanban" ? "kanban" : "list",
          sortOrder: projects.size,
          archived: false,
        });
      }
    }
    const columnName = fitName(get("column name"), LIMITS.sectionName);
    let sectionKey: string | null = null;
    if (columnName && projectKey) {
      sectionKey = derivedKey(projectKey, "column", columnName);
      if (!sections.has(sectionKey)) {
        sections.set(sectionKey, {
          key: sectionKey,
          projectKey,
          name: columnName,
          sortOrder: Number(get("column order")) || sections.size,
        });
      }
    }

    const zone = isTimeZone(get("timezone")) ? get("timezone") : ctx.timeZone;
    const allDay = truthy(get("is all day"));
    const when = parseDateText(get("due date") || get("start date"), zone);
    let notes: string | null = get("content") || null;
    const status = get("status").trim();
    const done = status === "1" || status === "2" || status === "-1";
    if (status === "-1") notes = addNote(notes, "أُغلقت في TickTick دون إنجاز.");
    let recurrence: string | null = null;
    const repeat = get("repeat");
    if (repeat) {
      recurrence = when ? zimamRule(repeat, when.date) : null;
      if (!recurrence) {
        notes = addNote(notes, `التكرار في TickTick: ${repeat}`);
        warnings.add("recurrenceKept");
      }
    }
    const completedAt = parseDateText(get("completed time"), "UTC");
    const taskId = get("taskid");
    const key = taskId ? nativeKey("task", taskId) : derivedKey(projectKey, sectionKey, "task", title, tasks.length);

    const reminders: ImportedReminder[] = [];
    const triggers = get("reminder")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    if (triggers.length) {
      if (!when || done || recurrence) {
        warnings.add("remindersSkipped", triggers.length);
      } else {
        const base = localToInstant(when.date, allDay || !when.time ? "00:00" : when.time, zone);
        for (const trigger of triggers) {
          const offset = durationMs(trigger.replace(/^TRIGGER:/i, ""));
          if (offset === null) {
            warnings.add("remindersSkipped");
            continue;
          }
          reminders.push({ key: `${key}/reminder:${trigger}`, at: isoWithOffset(base + offset, ctx.timeZone) });
        }
      }
    }

    tasks.push({
      key,
      projectKey,
      sectionKey,
      parentKey: get("parentid") ? nativeKey("task", get("parentid")) : null,
      title,
      notes,
      priority: tickTickPriority(get("priority")),
      tags: get("tags")
        .split(/[,،]/)
        .map((t) => t.trim())
        .filter(Boolean),
      dueDate: when?.date ?? null,
      dueTime: allDay ? null : (when?.time ?? null),
      recurrence,
      done,
      completedAt: done && completedAt ? Date.parse(`${completedAt.date}T${completedAt.time ?? "00:00"}:00Z`) : null,
      sortOrder: Number(get("order")) || 0,
      reminders,
    });
  }
  return {
    projects: [...projects.values()],
    sections: [...sections.values()],
    tasks: orderTasks(tasks).map(fitTask),
    warnings: warnings.list(),
  };
}

export const tickTickCsv: FileSource = {
  id: "ticktick-csv",
  label: "TickTick",
  refSource: "ticktick",
  input: "file",
  extensions: [".csv"],
  parse: parseTickTickCsv,
};
