import { z } from "zod";
import { TaskFields } from "../assistant";
import { dayOfHijri } from "../data/dates";
import type { PRAYERS } from "../data/schemas";

/**
 * Model output is untrusted: each answer is checked with zod, cleaned of emoji and
 * decoration, and anything that points outside the user's data is dropped.
 */

const DECORATION = /[\p{Extended_Pictographic}\u{FE0F}\u{FE0E}\u{200D}\u{20E3}\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}]/gu;

/** Removes emoji and markdown emphasis, and collapses whitespace inside lines. */
export function cleanText(text: string): string {
  return text
    .replace(DECORATION, "")
    .replace(/\*\*|__|`/g, "")
    .split("\n")
    .map((line) => line.replace(/[ \t ]+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** A one-line title: no emoji, no tatweel, no trailing punctuation or list markers. */
function cleanTitle(text: string): string {
  return cleanText(text)
    .replace(/\s+/g, " ")
    .replace(/ـ/g, "")
    .replace(/^([-*•]|\d+[.)-]|[٠-٩]+[.)-])\s*/u, "")
    .replace(/[.،,؛;:!؟?]+$/u, "")
    .trim();
}

// MARK: Natural-language task

const ModelSuggestion = TaskFields.pick({
  notes: true,
  dueDate: true,
  dueTime: true,
  duePrayer: true,
  duePrayerOffset: true,
  priority: true,
  tags: true,
}).extend({
  title: z.string(),
  dueHijri: z
    .object({ year: z.number().int().nullable().optional(), month: z.number().int(), day: z.number().int() })
    .nullable()
    .optional(),
  projectId: z.string().nullable().optional(),
  place: z
    .object({ placeId: z.string().nullable().optional(), name: z.string(), trigger: z.enum(["arrive", "leave"]) })
    .nullable()
    .optional(),
});

/**
 * A place the note ties the reminder to. `placeId` is one of the user's saved places, with its
 * saved name; without it the user named a place they have not saved, and the app says so.
 */
export interface PlaceSuggestion {
  placeId?: string;
  name: string;
  trigger: "arrive" | "leave";
}

export interface TaskSuggestion {
  title: string;
  notes?: string;
  dueDate?: string;
  dueTime?: string;
  duePrayer?: (typeof PRAYERS)[number];
  duePrayerOffset?: number;
  priority: "none" | "low" | "medium" | "high";
  tags: string[];
  projectId?: string;
  place?: PlaceSuggestion;
}

/** Null when the model's answer does not hold a usable task. */
export function validateSuggestion(
  json: unknown,
  today: string,
  projectIds: Set<string>,
  places: ReadonlyMap<string, string> = new Map(),
): TaskSuggestion | null {
  const parsed = ModelSuggestion.safeParse(json);
  if (!parsed.success) return null;
  const m = parsed.data;

  const title = TaskFields.shape.title.safeParse(cleanTitle(m.title));
  if (!title.success || !title.data) return null;
  const suggestion: TaskSuggestion = { title: title.data, priority: m.priority ?? "none", tags: [] };

  const notes = m.notes ? cleanText(m.notes) : "";
  if (notes) suggestion.notes = notes;

  // A Hijri date is converted here with Umm al-Qura, not by the model.
  const dueDate = m.dueHijri ? dayOfHijri(m.dueHijri, today) : m.dueDate;
  if (dueDate) suggestion.dueDate = dueDate;

  // A Hijri date that does not exist (the 30th of a 29-day month) leaves the task undated: its
  // time or prayer belongs to that day, and kept alone it would mean today, here and in the app.
  if (!(m.dueHijri && !dueDate)) {
    if (m.duePrayer) {
      suggestion.duePrayer = m.duePrayer;
      suggestion.duePrayerOffset = m.duePrayerOffset ?? 0;
    } else if (m.dueTime) {
      suggestion.dueTime = m.dueTime;
    }
  }
  // A time or prayer without a day means today.
  if (!suggestion.dueDate && (suggestion.dueTime || suggestion.duePrayer)) suggestion.dueDate = today;

  const tags = new Set<string>();
  for (const tag of m.tags ?? []) {
    const clean = cleanTitle(tag.replace(/^#+/, ""));
    if (clean && clean.length <= 50) tags.add(clean);
  }
  suggestion.tags = [...tags];

  const projectId = m.projectId?.trim().toLowerCase();
  if (projectId && projectIds.has(projectId)) suggestion.projectId = projectId;

  if (m.place) {
    const placeId = m.place.placeId?.trim().toLowerCase();
    const saved = placeId ? places.get(placeId) : undefined;
    if (placeId && saved !== undefined) {
      suggestion.place = { placeId, name: saved, trigger: m.place.trigger };
    } else {
      const name = cleanTitle(m.place.name);
      if (name && name.length <= 200) suggestion.place = { name, trigger: m.place.trigger };
    }
  }
  return suggestion;
}

// MARK: Subtasks

const ModelSubtasks = z.object({ subtasks: z.array(z.string()).max(30) });

/** Three to eight distinct, short subtask titles, or null. */
export function validateSubtasks(json: unknown, taskTitle: string): string[] | null {
  const parsed = ModelSubtasks.safeParse(json);
  if (!parsed.success) return null;
  const seen = new Set<string>([cleanTitle(taskTitle)]);
  const subtasks: string[] = [];
  for (const raw of parsed.data.subtasks) {
    const title = cleanTitle(raw);
    if (!title || title.length > 200 || seen.has(title)) continue;
    seen.add(title);
    subtasks.push(title);
  }
  return subtasks.length >= 3 ? subtasks.slice(0, 8) : null;
}

// MARK: Morning summary

const ModelSummary = z.object({ text: z.string() });

export function validateSummary(json: unknown): string | null {
  const parsed = ModelSummary.safeParse(json);
  if (!parsed.success) return null;
  const text = cleanText(parsed.data.text);
  return text && text.length <= 3000 ? text : null;
}
