// Pure helpers for task lists. Tasks are the API's shape (see api/DEVELOPMENT.md).
import { minuteOfDay, orderDay } from "./calendar.js";
import { arabicNumber } from "./numbers.js";

/** API priority 0–3 → the TaskRow flag ("low" | "medium" | "high"), or null for none. */
export function priorityKey(priority) {
  return { 1: "low", 2: "medium", 3: "high" }[priority] ?? null;
}

/** The priorities 0–3 by name, as a picker lists them («عالية»), and as words that stand alone («أولوية عالية»). */
export const PRIORITY_NAMES = { 0: "بلا أولوية", 1: "منخفضة", 2: "متوسطة", 3: "عالية" };
export const PRIORITY_WORDS = Object.fromEntries(Object.entries(PRIORITY_NAMES).map(([level, name]) => [level, Number(level) ? `أولوية ${name}` : name]));

export const isOpen = (task) => task.status !== "done";

/** Tasks grouped by due date in ascending order: [{ date, tasks }]. Undated tasks are left out. */
export function groupByDay(tasks) {
  const groups = new Map();
  for (const task of tasks) {
    if (!task.dueDate) continue;
    if (!groups.has(task.dueDate)) groups.set(task.dueDate, []);
    groups.get(task.dueDate).push(task);
  }
  // Each day as the app orders it (TodayTasks.ordered): by time of day, then manual order.
  return [...groups.keys()].sort().map((date) => ({ date, tasks: orderDay(groups.get(date)) }));
}

/**
 * Today's list as the app shows it (TodayView.swift): open top-level tasks due today or earlier,
 * by date then time of day (a prayer at its usual time), all-day tasks of a day before its timed ones.
 */
export function todayList(tasks, today) {
  return tasks
    .filter((t) => !t.parentId && t.dueDate && t.dueDate <= today)
    .map((task, index) => ({ task, index, minute: minuteOfDay(task) }))
    // As TodayTasks.ordered in the app: by day, then time of day (a prayer at its usual time,
    // untimed first), then manual order.
    .sort(
      (a, b) =>
        cmp(a.task.dueDate, b.task.dueDate) ||
        a.minute - b.minute ||
        (a.task.sortOrder ?? 0) - (b.task.sortOrder ?? 0) ||
        (a.task.createdAt ?? 0) - (b.task.createdAt ?? 0) ||
        a.index - b.index,
    )
    .map(({ task }) => task);
}

const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/** Top-level tasks only: subtasks show inside their task, never as rows of their own. */
export const topLevel = (tasks) => tasks.filter((t) => !t.parentId);

/** «٧ من ١٢». */
export function progressText(done, total) {
  return `${arabicNumber(done)} من ${arabicNumber(total)}`;
}

/** «مهمة واحدة», «مهمتان», «٣ مهام», «١١ مهمة». */
export function taskCount(n) {
  if (n === 0) return "لا مهام";
  if (n === 1) return "مهمة واحدة";
  if (n === 2) return "مهمتان";
  if (n >= 3 && n <= 10) return `${arabicNumber(n)} مهام`;
  return `${arabicNumber(n)} مهمة`;
}
