// Pure helpers for task lists. Tasks are the API's shape (see api/DEVELOPMENT.md).
import { arabicNumber } from "./numbers.js";

/** API priority 0–3 → the TaskRow flag ("low" | "medium" | "high"), or null for none. */
export function priorityKey(priority) {
  return { 1: "low", 2: "medium", 3: "high" }[priority] ?? null;
}

export const PRIORITY_WORDS = { 0: "بلا أولوية", 1: "أولوية منخفضة", 2: "أولوية متوسطة", 3: "أولوية عالية" };

export const isOpen = (task) => task.status !== "done";

/** Tasks grouped by due date in ascending order: [{ date, tasks }]. Undated tasks are left out. */
export function groupByDay(tasks) {
  const groups = new Map();
  for (const task of tasks) {
    if (!task.dueDate) continue;
    if (!groups.has(task.dueDate)) groups.set(task.dueDate, []);
    groups.get(task.dueDate).push(task);
  }
  return [...groups.keys()].sort().map((date) => ({ date, tasks: groups.get(date) }));
}

/** Today's list: overdue first (oldest first), then today's, each in the server's order. */
export function splitToday(tasks, today) {
  const overdue = tasks.filter((t) => t.dueDate && t.dueDate < today);
  const due = tasks.filter((t) => t.dueDate === today);
  return { overdue, due };
}

/** «٧ من ١٢». */
export function progressText(done, total) {
  return `${arabicNumber(done)} من ${arabicNumber(total)}`;
}

export function progressPercent(done, total) {
  return total > 0 ? Math.round((done / total) * 100) : 0;
}

/** «مهمة واحدة», «مهمتان», «٣ مهام», «١١ مهمة». */
export function taskCount(n) {
  if (n === 0) return "لا مهام";
  if (n === 1) return "مهمة واحدة";
  if (n === 2) return "مهمتان";
  if (n >= 3 && n <= 10) return `${arabicNumber(n)} مهام`;
  return `${arabicNumber(n)} مهمة`;
}
