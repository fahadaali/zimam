// Multi-day tasks: a task with `startDate` and `dueDate` occupies every day from its start to its
// due date, both included; without `startDate` it occupies its due date only. `startDate` is valid
// only with a due date and never after it (the API's rule). These are the calendar's rules for
// spanning bars in the month and week grids, and the date checks of «تاريخ البداية».
// Pure functions, no DOM; tested in test/spans.test.mjs.
import { addDays, dayDiff, dualDate, isIsoDate } from "./dates.js";
import { orderDay } from "./calendar.js";

/** Longest span expanded day by day; anything longer is cut at this many days. */
const MAX_SPAN_DAYS = 366;

/** The days a task occupies: { start, end } (inclusive), or null for an undated task. */
export function taskSpan(task) {
  if (!task || !isIsoDate(task.dueDate)) return null;
  const start = isIsoDate(task.startDate) && task.startDate <= task.dueDate ? task.startDate : task.dueDate;
  return { start, end: task.dueDate };
}

/** Days in a span, both ends included: 1 for a one-day task. */
export const spanLength = (span) => dayDiff(span.start, span.end) + 1;

export const isMultiDay = (task) => {
  const span = taskSpan(task);
  return !!span && span.start !== span.end;
};

/**
 * Checks a start date against a due date (both "YYYY-MM-DD", or empty for none):
 * null when valid, "needs_due" without a due date, "after_due" when it falls after it.
 */
export function checkStart(startDate, dueDate) {
  if (!startDate) return null;
  if (!isIsoDate(dueDate)) return "needs_due";
  return startDate > dueDate ? "after_due" : null;
}

/** Arabic messages for checkStart's codes. */
export const START_ERRORS = {
  needs_due: "تاريخ البداية يحتاج تاريخاً للمهمة. اختر التاريخ أولاً.",
  after_due: "تاريخ البداية بعد تاريخ المهمة. اختر يوماً قبله أو اليوم نفسه.",
};

/**
 * The fields to save for a new span. A span of one day keeps no start date (it is the same day),
 * so the task stays a plain dated task. → { startDate, dueDate }
 */
export function spanFields({ start, end }) {
  return { startDate: start && start !== end ? start : null, dueDate: end };
}

/**
 * Moving a task to `day` from the calendar: the due date becomes `day` and a start date moves by
 * the same number of days, so the span keeps its length. `startDate` is only in the result when
 * the task had one, so a server that does not know the field yet is never sent it.
 */
export function shiftTo(task, day) {
  if (!isIsoDate(task.startDate) || !isIsoDate(task.dueDate)) return { dueDate: day };
  return { startDate: addDays(task.startDate, dayDiff(task.dueDate, day)), dueDate: day };
}

/** Whether a span touches the days from `from` to `to` (inclusive). */
export const overlaps = (span, from, to) => !!span && span.start <= to && span.end >= from;

/**
 * Open top-level tasks by the days they occupy between `from` and `to`: { "2026-10-15": [task, …] },
 * each day in calendar order (lib/calendar.js orderDay). A multi-day task is under each of its days.
 */
export function tasksByOccupiedDay(tasks, from, to) {
  const out = {};
  for (const task of tasks) {
    if (task.parentId) continue;
    const span = taskSpan(task);
    if (!overlaps(span, from, to)) continue;
    let day = span.start < from ? from : span.start;
    const last = span.end > to ? to : span.end;
    for (let n = 0; day <= last && n < MAX_SPAN_DAYS; n++, day = addDays(day, 1)) (out[day] ??= []).push(task);
  }
  for (const day of Object.keys(out)) out[day] = orderDay(out[day]);
  return out;
}

/** Tasks that occupy a single day, by that day (the dots and chips in a day cell). */
export function singleDayByDay(tasks) {
  const out = {};
  for (const task of tasks) {
    if (task.parentId || !taskSpan(task) || isMultiDay(task)) continue;
    (out[task.dueDate] ??= []).push(task);
  }
  for (const day of Object.keys(out)) out[day] = orderDay(out[day]);
  return out;
}

/**
 * Spanning bars for one row of consecutive days (a week of the month grid, or the week view).
 * `days` are the row's days in column order ("YYYY-MM-DD", consecutive). Each multi-day task that
 * touches the row gets a bar from its first to its last column in the row, in the lowest lane free
 * across those columns; earlier starts first, then longer spans. Bars past `maxLanes` are hidden
 * and counted in `hidden` under each column they cover.
 * Columns are logical: 0 is the row's first day, at the inline start (the right edge in Arabic).
 * → { bars: [{ task, column, length, lane, continuesBefore, continuesAfter }], lanes, hidden: [n × days] }
 */
export function rowBars(days, tasks, { maxLanes = Infinity } = {}) {
  const first = days[0];
  const last = days[days.length - 1];
  const items = [];
  for (const task of tasks) {
    if (task.parentId || !isMultiDay(task)) continue;
    const span = taskSpan(task);
    if (!overlaps(span, first, last)) continue;
    const from = span.start < first ? first : span.start;
    const to = span.end > last ? last : span.end;
    items.push({ task, span, column: dayDiff(first, from), length: dayDiff(from, to) + 1 });
  }
  items.sort(
    (a, b) =>
      a.column - b.column ||
      b.length - a.length ||
      (a.span.start < b.span.start ? -1 : a.span.start > b.span.start ? 1 : 0) ||
      (a.task.sortOrder ?? 0) - (b.task.sortOrder ?? 0) ||
      String(a.task.id).localeCompare(String(b.task.id)),
  );
  const laneEnds = []; // per lane: the last column taken
  const bars = [];
  const hidden = days.map(() => 0);
  for (const item of items) {
    let lane = laneEnds.findIndex((end) => end < item.column);
    if (lane === -1) lane = laneEnds.length;
    laneEnds[lane] = item.column + item.length - 1;
    if (lane >= maxLanes) {
      for (let c = item.column; c < item.column + item.length; c++) hidden[c]++;
      continue;
    }
    bars.push({
      task: item.task,
      column: item.column,
      length: item.length,
      lane,
      continuesBefore: item.span.start < first,
      continuesAfter: item.span.end > last,
    });
  }
  return { bars, lanes: Math.min(laneEnds.length, maxLanes), hidden };
}

/** «من ٢ جمادى الأولى، ١٣ أكتوبر إلى ٥ جمادى الأولى، ١٦ أكتوبر», or the one day for a one-day span. */
export function spanText(span, { primary = "hijri", today } = {}) {
  if (!span) return "بلا تاريخ";
  const end = dualDate(span.end, { primary, today });
  if (span.start === span.end) return end;
  return `من ${dualDate(span.start, { primary, today })} إلى ${end}`;
}
