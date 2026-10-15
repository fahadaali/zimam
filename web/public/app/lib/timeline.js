// «المخطط الزمني» (Gantt): the scale under the bars. Time runs along the inline axis, so in Arabic
// it flows from right to left: day 0 of the range is at the inline start (the right edge), and a
// later day is further toward the left. Positions here are logical — days from the range's first
// day — and CSS places them with inset-inline-start, so the same numbers draw correctly in both
// directions. Only the pointer, which the browser reports in physical pixels from the left, needs
// the direction (dayAtPointer, pointerDelta).
// Pure functions, no DOM; tested in test/timeline.test.mjs.
import { addDays, dayDiff, parseIsoDate } from "./dates.js";
import { calendarParts, monthYear, otherKind, weekday } from "./calendar.js";
import { arabicNumber } from "./numbers.js";
import { spanFields, taskSpan } from "./spans.js";

/** The two zoom levels: a column per day, or a column per week. */
export const ZOOMS = {
  day: { padding: 3, minDays: 28 },
  week: { padding: 7, minDays: 84 },
};
/** The longest range drawn, so a stray date years away does not draw thousands of columns. */
export const MAX_DAYS = 3 * 366;

const zoomOf = (zoom) => ZOOMS[zoom] ?? ZOOMS.day;

/**
 * The days the timeline shows: every span and today, a little padding on both sides, at least the
 * zoom's minimum, and in the week zoom whole weeks starting on `weekStart`. → { from, to, days }
 */
export function timelineRange(spans, today, { zoom = "day", weekStart = 0 } = {}) {
  const { padding, minDays } = zoomOf(zoom);
  let from = today;
  let to = today;
  for (const span of spans) {
    if (!span) continue;
    if (span.start < from) from = span.start;
    if (span.end > to) to = span.end;
  }
  from = addDays(from, -padding);
  to = addDays(to, padding);
  // Keep today in view when the dates are far apart: cut the far end first.
  if (dayDiff(from, to) + 1 > MAX_DAYS) {
    const before = dayDiff(from, today);
    if (before > MAX_DAYS / 2) from = addDays(today, -Math.floor(MAX_DAYS / 2));
    to = addDays(from, MAX_DAYS - 1);
  }
  if (dayDiff(from, to) + 1 < minDays) to = addDays(from, minDays - 1);
  if (zoom === "week") {
    from = addDays(from, -((weekday(from) - weekStart + 7) % 7));
    const days = dayDiff(from, to) + 1;
    to = addDays(from, Math.ceil(days / 7) * 7 - 1);
  }
  return { from, to, days: dayDiff(from, to) + 1 };
}

/** A span's place on the scale: { start, length } in days from `from` (start may be negative). */
export function barPlace(span, from) {
  return { start: dayDiff(from, span.start), length: dayDiff(span.start, span.end) + 1 };
}

/**
 * The months the range crosses in one calendar, as header segments in logical order:
 * [{ key, label, start, length }] with `start` in days from `from`.
 */
export function monthSegments(from, days, kind) {
  const out = [];
  for (let i = 0; i < days; i++) {
    const iso = addDays(from, i);
    const { year, month } = calendarParts(iso, kind);
    const key = `${kind}-${year}-${month}`;
    const last = out[out.length - 1];
    if (last?.key === key) last.length++;
    else out.push({ key, label: monthYear(iso, kind), start: i, length: 1 });
  }
  return out;
}

/** The header's month rows: the primary calendar's months, then the other calendar's. */
export function headerMonths(from, days, primary) {
  return [monthSegments(from, days, primary), monthSegments(from, days, otherKind(primary))];
}

/**
 * The header's finest row. Day zoom: one cell per day with its day in both calendars. Week zoom:
 * one cell per week, «٧ – ١٣» in the primary calendar.
 * → [{ day, start, length, label, secondary, isToday }]
 */
export function scaleCells(from, days, { zoom = "day", primary = "hijri", today } = {}) {
  const out = [];
  const step = zoom === "week" ? 7 : 1;
  for (let i = 0; i < days; i += step) {
    const day = addDays(from, i);
    const length = Math.min(step, days - i);
    const end = addDays(day, length - 1);
    const label =
      step === 1
        ? arabicNumber(calendarParts(day, primary).day)
        : `${arabicNumber(calendarParts(day, primary).day)} – ${arabicNumber(calendarParts(end, primary).day)}`;
    const secondary = step === 1 ? arabicNumber(calendarParts(day, otherKind(primary)).day) : null;
    out.push({ day, start: i, length, label, secondary, isToday: today != null && today >= day && today <= end });
  }
  return out;
}

/**
 * The day under the pointer: days from the range's first day. `trackLeft` and `trackRight` are the
 * track's physical edges (getBoundingClientRect), `dayWidth` the width of one day. In right-to-left
 * the first day is at the right edge.
 */
export function dayAtPointer(clientX, { trackLeft, trackRight, dayWidth, rtl = true }) {
  const fromStart = rtl ? trackRight - clientX : clientX - trackLeft;
  return Math.floor(fromStart / dayWidth);
}

/** Whole days a pointer moved along the timeline, positive toward later days (leftward in Arabic). */
export function pointerDelta(startX, x, { dayWidth, rtl = true }) {
  const moved = rtl ? startX - x : x - startX;
  const days = moved / dayWidth;
  return Math.sign(days) * Math.round(Math.abs(days)) || 0;
}

/**
 * A span after a drag of `delta` days. `mode`: "move" shifts both ends; "start" and "end" move one
 * end and never past the other, so a span is at least one day.
 */
export function dragSpan(span, mode, delta) {
  if (mode === "move") return { start: addDays(span.start, delta), end: addDays(span.end, delta) };
  if (mode === "start") {
    const start = addDays(span.start, delta);
    return { start: start > span.end ? span.end : start, end: span.end };
  }
  if (mode === "end") {
    const end = addDays(span.end, delta);
    return { start: span.start, end: end < span.start ? span.start : end };
  }
  throw new RangeError(`Unknown drag mode: ${mode}`);
}

/**
 * The PATCH for a new span: { startDate, dueDate }, or null when nothing changed. A one-day span
 * has no start date. `startDate: null` is left out for a task that never had one, so a server that
 * does not know the field is not sent it.
 */
export function spanPatch(task, span) {
  const next = spanFields(span);
  const before = taskSpan(task);
  if (before && before.start === span.start && before.end === span.end) return null;
  const patch = { dueDate: next.dueDate };
  if (next.startDate != null || task.startDate != null) patch.startDate = next.startDate;
  return patch;
}

/**
 * The scroll position (scrollLeft) that puts day `index` in the middle of the visible track.
 * `labelWidth` is the sticky label column at the inline start. In right-to-left, scrollLeft is 0 at
 * the start and negative toward the end (the CSSOM rule every current browser follows).
 */
export function scrollFor(index, { dayWidth, labelWidth, viewport, rtl = true }) {
  const track = Math.max(0, viewport - labelWidth);
  const offset = Math.max(0, index * dayWidth + dayWidth / 2 - track / 2);
  return rtl ? -offset || 0 : offset;
}

/**
 * Rows grouped under headings, in order. `groups` are [{ id, name }] (sections of a project, or
 * projects); `groupOf(task)` names a task's group, and tasks whose group is not listed go to the
 * first one. Inside a group: dated tasks by start, then due date, then manual order; undated last
 * when `undated` is true, left out otherwise. Empty groups are left out.
 * → [{ id, name, tasks }]
 */
export function groupRows(tasks, groups, groupOf, { undated = true } = {}) {
  const known = new Set(groups.map((g) => g.id));
  const fallback = groups[0]?.id;
  const buckets = new Map(groups.map((g) => [g.id, []]));
  for (const task of tasks) {
    if (task.parentId) continue;
    if (!undated && !taskSpan(task)) continue;
    const id = groupOf(task);
    buckets.get(known.has(id) ? id : fallback)?.push(task);
  }
  const order = (a, b) => {
    const sa = taskSpan(a);
    const sb = taskSpan(b);
    if (!sa || !sb) return sa ? -1 : sb ? 1 : (a.sortOrder ?? 0) - (b.sortOrder ?? 0);
    if (sa.start !== sb.start) return sa.start < sb.start ? -1 : 1;
    if (sa.end !== sb.end) return sa.end < sb.end ? -1 : 1;
    return (a.sortOrder ?? 0) - (b.sortOrder ?? 0) || (a.createdAt ?? 0) - (b.createdAt ?? 0);
  };
  return groups.map((g) => ({ id: g.id, name: g.name, tasks: buckets.get(g.id).sort(order) })).filter((g) => g.tasks.length);
}

/** Whether `iso` is a real day inside the range. */
export const inRange = (iso, { from, to }) => {
  try {
    parseIsoDate(iso);
  } catch {
    return false;
  }
  return iso >= from && iso <= to;
};
