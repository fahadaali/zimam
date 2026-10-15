// «المصفوفة»: open tasks in four quadrants by importance and urgency, the same rules as the Apple
// app and the widgets:
//   important := priority ≥ 2 (medium or high)
//   urgent    := a due date on or before tomorrow (overdue included), in the user's time zone
//                (settings.timeZone)
// Done tasks are in no quadrant.
//
// Moving a task between quadrants changes the fewest fields that put it there:
//   - into an important quadrant: priority becomes 2 (medium) when it is below 2; 3 stays 3.
//   - out of the important ones:  priority becomes 0 (none).
//   - into an urgent quadrant:    the due date becomes today when the task has none or it is later
//                                 than tomorrow (a due date of today or tomorrow already counts);
//                                 a start date after the new due date is cleared.
//   - out of the urgent ones:     the due date (and with it the start date) is cleared, only after
//                                 the person confirms; without that nothing moves.
// Pure functions, no DOM; tested in test/matrix.test.mjs.
import { addDays, isIsoDate } from "./dates.js";

export const QUADRANTS = [
  { key: "urgent-important", title: "مهم وعاجل", important: true, urgent: true },
  { key: "important", title: "مهم", important: true, urgent: false },
  { key: "urgent", title: "عاجل", important: false, urgent: true },
  { key: "someday", title: "يوماً ما", important: false, urgent: false },
];

export const quadrant = (key) => QUADRANTS.find((q) => q.key === key) ?? null;

/** Rows a quadrant shows before «+n أخرى». */
export const VISIBLE_ROWS = 5;

/** Today as "YYYY-MM-DD" in an IANA time zone (the user's settings.timeZone); the device's day if it is unknown. */
export function todayIn(timeZone, now = new Date()) {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(now);
    const get = (type) => parts.find((p) => p.type === type)?.value;
    const iso = `${get("year")}-${get("month")}-${get("day")}`;
    if (isIsoDate(iso)) return iso;
  } catch {
    /* unknown zone: fall through */
  }
  const pad = (n) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

export const isImportant = (task) => (task.priority ?? 0) >= 2;
export const isUrgent = (task, today) => isIsoDate(task.dueDate) && task.dueDate <= addDays(today, 1);

/** The quadrant key of an open task; null for a done one. */
export function quadrantOf(task, today) {
  if (task.status === "done") return null;
  const important = isImportant(task);
  const urgent = isUrgent(task, today);
  return QUADRANTS.find((q) => q.important === important && q.urgent === urgent).key;
}

/** Order inside a quadrant: earliest due date first (undated last), then higher priority, then manual order. */
export function byUrgency(a, b) {
  const da = a.dueDate ?? "9999-12-31";
  const db = b.dueDate ?? "9999-12-31";
  if (da !== db) return da < db ? -1 : 1;
  return (b.priority ?? 0) - (a.priority ?? 0) || (a.sortOrder ?? 0) - (b.sortOrder ?? 0) || (a.createdAt ?? 0) - (b.createdAt ?? 0);
}

/** Open top-level tasks in their quadrants: { "urgent-important": [task, …], … }, each sorted. */
export function quadrants(tasks, today) {
  const out = Object.fromEntries(QUADRANTS.map((q) => [q.key, []]));
  for (const task of tasks) {
    if (task.parentId) continue;
    const key = quadrantOf(task, today);
    if (key) out[key].push(task);
  }
  for (const key of Object.keys(out)) out[key].sort(byUrgency);
  return out;
}

/**
 * What moving `task` to quadrant `to` changes. → { patch, clearsDueDate }
 * `patch` is the fields to send (empty when it is already there). `clearsDueDate` is true when the
 * move takes the task out of the urgent quadrants, which needs the person's confirmation first.
 * `startDate` is only in the patch when the task has one, so a server without the field is never sent it.
 */
export function moveToQuadrant(task, to, today) {
  const target = quadrant(to);
  if (!target) throw new RangeError(`Unknown quadrant: ${to}`);
  const patch = {};
  const important = isImportant(task);
  if (target.important && !important) patch.priority = 2;
  if (!target.important && important) patch.priority = 0;

  const urgent = isUrgent(task, today);
  let clearsDueDate = false;
  if (target.urgent && !urgent) {
    patch.dueDate = today;
    if (isIsoDate(task.startDate) && task.startDate > today) patch.startDate = null;
  } else if (!target.urgent && urgent) {
    clearsDueDate = true;
    patch.dueDate = null;
    if (task.startDate != null) patch.startDate = null;
  }
  return { patch, clearsDueDate };
}

/** «+٢ أخرى» needs the count of rows past the visible ones. */
export const hiddenCount = (count, expanded) => (expanded ? 0 : Math.max(0, count - VISIBLE_ROWS));
