/**
 * What every source is mapped to before anything is written: plain records keyed
 * by the source's own ids. The importer (`apply.ts`) turns them into Zimam ids via
 * `external_refs` and writes them through the Mutator.
 */

/** A list, project or folder in the source. */
export interface ImportedProject {
  key: string;
  name: string;
  kind: "project" | "folder";
  /** The folder it sits in (a project whose kind is "folder"). */
  parentKey: string | null;
  view: "list" | "kanban" | "calendar";
  sortOrder: number;
  archived: boolean;
}

/** A section or kanban column. */
export interface ImportedSection {
  key: string;
  projectKey: string;
  name: string;
  sortOrder: number;
}

/** A time reminder: an instant with its UTC offset, e.g. "2026-10-20T09:00:00+03:00". */
export interface ImportedReminder {
  key: string;
  at: string;
}

export interface ImportedTask {
  key: string;
  /** Null: the user's inbox. */
  projectKey: string | null;
  sectionKey: string | null;
  parentKey: string | null;
  title: string;
  notes: string | null;
  /** 0 none, 1 low, 2 medium, 3 high. */
  priority: number;
  tags: string[];
  /** Local Gregorian day, "2026-10-20". */
  dueDate: string | null;
  /** Local "HH:mm". */
  dueTime: string | null;
  /**
   * The first day of a task that spans days, "2026-10-18", before its `dueDate`. Absent: the
   * source has no such field, and Zimam keeps what the user set. Null: the task spans no days.
   */
  startDate?: string | null;
  /** RFC 5545 RRULE without the "RRULE:" prefix. */
  recurrence: string | null;
  /** Only when the source marks the task completed. */
  done: boolean;
  completedAt: number | null;
  sortOrder: number;
  reminders: ImportedReminder[];
}

export interface ImportBundle {
  projects: ImportedProject[];
  sections: ImportedSection[];
  tasks: ImportedTask[];
  /** What could not be mapped and was kept as a note, or skipped (Arabic, for the user). */
  warnings: string[];
}

/** Thrown for input that will never import (bad file, rejected token): the job fails with this Arabic text. */
export class ImportError extends Error {
  constructor(
    readonly code: string,
    readonly arabic: string,
  ) {
    super(code);
    this.name = "ImportError";
  }
}

/** Thrown for failures worth retrying (provider down, rate limited). */
export class TransientImportError extends Error {
  constructor(
    message: string,
    /** Seconds the provider asked us to wait, if it said. */
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "TransientImportError";
  }
}

export const emptyBundle = (): ImportBundle => ({ projects: [], sections: [], tasks: [], warnings: [] });

const WARNING_TEXT = {
  recurrenceKept: "مهام لم يُفهم تكرارها، فحُفظ نصه في ملاحظاتها",
  dateKept: "مواعيد نسبية أو غير مفهومة، حُفظ نصها في ملاحظات مهامها",
  deadlineKept: "مواعيد نهائية حُفظت في الملاحظات لأن للمهمة موعداً آخر",
  untitledSkipped: "مهام بلا عنوان تُركت",
  notesSkipped: "ملاحظات ليست مهاماً تُركت",
  remindersSkipped: "تذكيرات لم تُنقل لأنها على مهام متكررة أو منجزة أو بلا موعد",
  sectionsDropped: "أقسام في صندوق الوارد لا تُنقل، فبقيت مهامها في الصندوق بلا قسم",
  deletedSkipped: "مهام محذوفة في المصدر تُركت",
  canceledSkipped: "مهام ملغاة في المصدر تُركت",
  archivedSkipped: "عناصر مؤرشفة أو في سلة المحذوفات تُركت",
  calendarsSkipped: "تقاويم العطل وأعياد الميلاد لم تُنقل",
  seriesExpanded: "مواعيد متكررة لا يعبّر عنها تكرار زمام، فنُقلت مرّاتها في المدة مهاماً منفصلة",
  flaggedEmailsSkipped: "قائمة الرسائل المعلَّمة في Outlook لم تُنقل لأنها رسائل لا مهام",
  databasesSkipped: "قواعد بيانات Notion بلا عمود عنوان لم تُنقل",
} as const;

export type WarningKind = keyof typeof WARNING_TEXT;

/** Arabic-Indic digits, no grouping: «١٢». */
export const arabicNumber = (n: number) => new Intl.NumberFormat("ar-SA", { useGrouping: false }).format(n);

/** Counts what a parser could not map, and words it for the user: «مهام بلا عنوان تُركت: ٣». */
export class Warnings {
  private counts = new Map<WarningKind, number>();

  add(kind: WarningKind, n = 1) {
    this.counts.set(kind, (this.counts.get(kind) ?? 0) + n);
  }

  list(): string[] {
    return [...this.counts].map(([kind, n]) => `${WARNING_TEXT[kind]}: ${arabicNumber(n)}`);
  }
}

export const LIMITS = {
  projectName: 200,
  sectionName: 100,
  title: 500,
  notes: 20_000,
  tag: 50,
  tags: 30,
} as const;

/** Keeps a record inside the schema limits without losing text: an over-long title goes whole into the notes. */
export function fitTask(t: ImportedTask): ImportedTask {
  let { title, notes } = t;
  title = title.replace(/\s+/g, " ").trim();
  if (title.length > LIMITS.title) {
    notes = notes ? `${title}\n\n${notes}` : title;
    title = `${title.slice(0, LIMITS.title - 1)}…`;
  }
  if (notes !== null) {
    notes = notes.trim() || null;
    if (notes && notes.length > LIMITS.notes) notes = `${notes.slice(0, LIMITS.notes - 1)}…`;
  }
  const tags = [...new Set(t.tags.map((tag) => tag.trim().slice(0, LIMITS.tag).trim()).filter(Boolean))].slice(0, LIMITS.tags);
  const out = { ...t, title, notes, tags };
  // A start day only before a due day: Zimam refuses one on or after it, or without one.
  if (out.startDate != null && (out.dueDate === null || out.startDate >= out.dueDate)) out.startDate = null;
  return out;
}

export function fitName(name: string, max: number): string {
  const clean = name.replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

/** Appends a labelled line to notes. */
export function addNote(notes: string | null, line: string): string {
  return notes ? `${notes}\n\n${line}` : line;
}

/**
 * Orders tasks so a parent always comes before its subtasks, and drops the parent
 * link of a task whose parent is missing or in another project (it becomes a top-level task).
 */
export function orderTasks(tasks: ImportedTask[]): ImportedTask[] {
  const byKey = new Map(tasks.map((t) => [t.key, t]));
  const out: ImportedTask[] = [];
  const placed = new Set<string>();
  const visiting = new Set<string>();
  const visit = (t: ImportedTask) => {
    if (placed.has(t.key)) return;
    visiting.add(t.key);
    const parent = t.parentKey ? byKey.get(t.parentKey) : undefined;
    // A missing parent, one in another project, or a cycle: the task becomes top-level.
    if (!parent || parent.projectKey !== t.projectKey || visiting.has(parent.key)) t.parentKey = null;
    else visit(parent);
    visiting.delete(t.key);
    placed.add(t.key);
    out.push(t);
  };
  for (const t of tasks) visit(t);
  return out;
}
