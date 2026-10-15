// Manual order for the kanban board: tasks inside a column and the columns (sections) themselves.
// The same rules as ManualOrder in apple/ZimamKit and Store+Board.swift, so a move made on the web
// and one made in the app give the same orders. Lists sort by `sortOrder` ascending, then by
// creation time where two orders are equal. Pure functions, no DOM; tested in test/order.test.mjs.

/** An order strictly between two neighbours (null for none), or null when they leave no room. */
export function between(before, after) {
  if (before == null && after == null) return 1;
  if (after == null) return before + 1;
  if (before == null) return after - 1;
  const middle = before + (after - before) / 2;
  return before < middle && middle < after ? middle : null;
}

/** 1, 2, 3… for a list of `count` items. */
export function renumbered(count) {
  return Array.from({ length: Math.max(count, 0) }, (_, i) => i + 1);
}

/**
 * The orders of a list after inserting one item at `index`. `orders` are the list's current
 * orders in display order, without the moved item. Only the new item's order is new whenever its
 * neighbours leave room; otherwise (equal neighbours, as in a list never ordered by hand) the whole
 * list is renumbered 1, 2, 3… and every item whose order changed is saved.
 */
export function inserting(index, orders) {
  const at = Math.min(Math.max(index, 0), orders.length);
  const order = between(at > 0 ? orders[at - 1] : null, at < orders.length ? orders[at] : null);
  if (order === null) return renumbered(orders.length + 1);
  const result = orders.slice();
  result.splice(at, 0, order);
  return result;
}

/** The orders after moving the item at `from` to position `to`, counted in the list without it. */
export function moving(from, to, orders) {
  if (from < 0 || from >= orders.length) return orders.slice();
  const rest = orders.slice();
  rest.splice(from, 1);
  return inserting(to, rest);
}

/** An order after every one of `orders`, for an item added at the end. */
export function after(orders) {
  return (orders.length ? Math.max(...orders) : 0) + 1;
}

/** Board order: `sortOrder`, then creation time, then id so the order is total. */
export function byManualOrder(a, b) {
  return (a.sortOrder ?? 0) - (b.sortOrder ?? 0) || (a.createdAt ?? 0) - (b.createdAt ?? 0) || String(a.id).localeCompare(String(b.id));
}

export const UNSECTIONED = "unsectioned";

/**
 * The board's columns: «بلا قسم» first (tasks with no section, or one that no longer exists), then
 * each section in order. `tasks` are the project's top-level tasks; `keep(task)` decides which show
 * (the open ones, and a just-completed one while it lingers).
 * → [{ id, section, name, tasks }]
 */
export function boardColumns(sections, tasks, keep = (t) => t.status !== "done") {
  const ordered = sections.slice().sort(byManualOrder);
  const known = new Set(ordered.map((s) => s.id));
  const visible = tasks.filter((t) => !t.parentId && keep(t)).sort(byManualOrder);
  const loose = visible.filter((t) => !t.sectionId || !known.has(t.sectionId));
  return [
    { id: UNSECTIONED, section: null, name: "بلا قسم", tasks: loose },
    ...ordered.map((s) => ({ id: s.id, section: s, name: s.name, tasks: visible.filter((t) => t.sectionId === s.id) })),
  ];
}

/** Columns the board shows: «بلا قسم» steps aside once sections exist and it is empty. */
export function shownColumns(columns) {
  const hasSections = columns.some((c) => c.section);
  return columns.filter((c) => c.section || c.tasks.length > 0 || !hasSections);
}

/**
 * Puts `task` in a column (`sectionId` null is «بلا قسم») at `index`, counted among `column`
 * without the task itself. Returns the changes to save: [{ id, sortOrder, sectionId }]. Usually
 * only the task; a column never ordered by hand is renumbered once.
 */
export function placeTask(task, sectionId, index, column) {
  const others = column.filter((t) => t.id !== task.id);
  const position = Math.min(Math.max(index, 0), others.length);
  const orders = inserting(position, others.map((t) => t.sortOrder ?? 0));
  const ordered = others.slice();
  ordered.splice(position, 0, task);
  const newSection = sectionId ?? null;
  const changedSection = (task.sectionId ?? null) !== newSection;
  const changes = [];
  ordered.forEach((item, i) => {
    const moved = item.id === task.id;
    if ((item.sortOrder ?? 0) !== orders[i] || (moved && changedSection)) {
      changes.push({ id: item.id, sortOrder: orders[i], sectionId: moved ? newSection : (item.sectionId ?? null) });
    }
  });
  return changes;
}

/** Moves a section one place earlier (−1) or later (+1). Returns [{ id, sortOrder }] to save. */
export function moveSection(sections, sectionId, offset) {
  const list = sections.slice().sort(byManualOrder);
  const from = list.findIndex((s) => s.id === sectionId);
  const to = from + offset;
  if (from === -1 || to < 0 || to >= list.length || to === from) return [];
  const orders = moving(from, to, list.map((s) => s.sortOrder ?? 0));
  const ordered = list.slice();
  const [moved] = ordered.splice(from, 1);
  ordered.splice(to, 0, moved);
  return ordered.flatMap((s, i) => ((s.sortOrder ?? 0) !== orders[i] ? [{ id: s.id, sortOrder: orders[i] }] : []));
}

/**
 * Where a dragged card lands among a column's cards, from the pointer's block position and each
 * card's vertical middle: the number of cards (other than the dragged one) above the pointer.
 */
export function dropIndex(pointerY, middles) {
  let index = 0;
  for (const middle of middles) if (pointerY > middle) index++;
  return index;
}
