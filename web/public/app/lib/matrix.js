// «المصفوفة»: open tasks in four quadrants by importance and urgency, the same rules as the Apple
// app and the widgets:
//   important := priority ≥ 2 (medium or high)
//   urgent    := a due date on or before tomorrow (overdue included); on the web «today» is the
//                device's day, as in every other view (main.js state.today)
// Done tasks are in no quadrant.
//
// Moving a task between quadrants changes the fewest fields that put it there (PriorityMatrix.move):
//   - into an important quadrant: priority becomes 2 (medium) when it is below 2; 3 stays 3.
//   - out of the important ones:  a medium or high priority becomes 1 (low).
//   - into an urgent quadrant:    the due date becomes today when the task is not urgent yet (a due
//                                 date of today, tomorrow or before already counts); its time or
//                                 prayer stays, and a start date moves with it, keeping the span.
//   - out of the urgent ones:     the due date is cleared, but only when nothing else is tied to it
//                                 (isAnchored: a time, a prayer, a repeat, a start date or a
//                                 reminder); otherwise the move is refused, and the person changes
//                                 the date in the task's details.
// Pure functions, no DOM; tested in test/matrix.test.mjs.
import { addDays, isIsoDate } from "./dates.js";
import { shiftTo } from "./spans.js";

export const QUADRANTS = [
  { key: "urgent-important", title: "مهم وعاجل", important: true, urgent: true },
  { key: "important", title: "مهم", important: true, urgent: false },
  { key: "urgent", title: "عاجل", important: false, urgent: true },
  { key: "someday", title: "يوماً ما", important: false, urgent: false },
];

export const quadrant = (key) => QUADRANTS.find((q) => q.key === key) ?? null;

/** Rows a quadrant shows before «+n أخرى». */
export const VISIBLE_ROWS = 5;

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

/** Whether the task's own fields tie its due date to more than the day (Store.isAnchored, without the reminders). */
export const anchoredByFields = (task) => !!(task.dueTime || task.duePrayer || task.recurrence || task.startDate);

/**
 * Whether clearing the due date would lose more than the day: a time, a prayer, a repeat, a start
 * date, or one of `reminderCount` reminders. A count that could not be read (null) counts as tied,
 * the safe answer, as the app does.
 */
export const isAnchored = (task, reminderCount) => anchoredByFields(task) || reminderCount !== 0;

/** Whether moving `task` to quadrant `to` takes it out of the urgent quadrants (and so clears its due date). */
export const leavesUrgent = (task, to, today) => !quadrant(to)?.urgent && isUrgent(task, today);

/**
 * What moving `task` to quadrant `to` changes. → { patch, refused }
 * `patch` is the fields to send (empty when it is already there). `anchored` (isAnchored) is only
 * read when the move leaves the urgent quadrants: then the move is `refused` and nothing changes.
 * `startDate` is only in the patch when the task has one.
 */
export function moveToQuadrant(task, to, today, { anchored = false } = {}) {
  const target = quadrant(to);
  if (!target) throw new RangeError(`Unknown quadrant: ${to}`);
  if (quadrantOf(task, today) === to) return { patch: {}, refused: false };
  const patch = {};
  const important = isImportant(task);
  if (target.important && !important) patch.priority = 2;
  if (!target.important && important) patch.priority = 1;

  const urgent = isUrgent(task, today);
  if (target.urgent && !urgent) Object.assign(patch, shiftTo(task, today));
  else if (!target.urgent && urgent) {
    if (anchored) return { patch: {}, refused: true };
    patch.dueDate = null;
  }
  return { patch, refused: false };
}

/** «+٢ أخرى» needs the count of rows past the visible ones. */
export const hiddenCount = (count, expanded) => (expanded ? 0 : Math.max(0, count - VISIBLE_ROWS));
