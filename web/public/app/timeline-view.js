// «المخطط الزمني» (Gantt): open tasks as bars from their start date to their due date, along a
// time axis that flows from right to left in Arabic, with the months in both calendars and the
// days (or weeks) under them, rows grouped by section (a project's timeline, #/projects/<id> with
// the «مخطط» view) or by project (#/timeline). A line marks today.
//   - Drag a bar to move it; drag its ends to change its start or due date. The PATCH sends both
//     dates together (lib/timeline.js spanPatch).
//   - «تغيير المدة…» on each row does the same from the keyboard: a dialog with two date fields.
// The scale math (range, positions, the pointer in right-to-left) is in lib/timeline.js; positions
// are days, placed by CSS with inset-inline-start, so no pixel value is written here.
// Plain DOM through h() and textContent; nothing here parses HTML.
import { Button, h } from "./lib/components.js";
import { dayDiff } from "./lib/dates.js";
import { boardApi } from "./lib/feature-api.js";
import { UNSECTIONED, byManualOrder } from "./lib/order.js";
import { spanText, taskSpan } from "./lib/spans.js";
import { barPlace, dragSpan, groupRows, headerMonths, pointerDelta, scaleCells, scrollFor, spanPatch, timelineRange } from "./lib/timeline.js";
import { isOpen } from "./lib/tasks.js";
import { openDurationDialog } from "./duration-view.js";

const ZOOM_KEY = "zimam.timeline.zoom";
const prefs = { zoom: readZoom() };

function readZoom() {
  try {
    return localStorage.getItem(ZOOM_KEY) === "week" ? "week" : "day";
  } catch {
    return "day";
  }
}

function saveZoom(zoom) {
  prefs.zoom = zoom;
  try {
    localStorage.setItem(ZOOM_KEY, zoom);
  } catch {
    /* the choice lasts for this page */
  }
}

/** Where each timeline (and zoom) was last scrolled, for this page's life: { from, logical }. */
const scrolled = new Map();

/** A drag must move this many pixels before it counts; less is a tap that opens the task. */
const TAP_SLOP = 4;

// ——— The two entry points ———

/** #/timeline: every open, dated task, grouped by project. */
export async function viewTimeline(ctx) {
  const { tasks, truncated } = await boardApi.tasks({ status: "open" });
  const top = tasks.filter((t) => !t.parentId);
  const ids = [...new Set(top.filter((t) => t.projectId).map((t) => t.projectId))];
  const groups = [
    { id: "inbox", name: "بلا مشروع" },
    ...ids.map((id) => ({ id, name: ctx.projectName(id) ?? "مشروع مشترك" })).sort((a, b) => a.name.localeCompare(b.name, "ar")),
  ];
  const header = h(
    "header",
    { className: "view-header" },
    h("h1", { className: "display view-title", tabindex: "-1" }, "المخطط الزمني"),
    h("p", { className: "callout muted" }, "مهامك المؤرخة من تاريخ بدايتها إلى موعدها."),
  );
  return [
    header,
    ...(truncated ? [ctx.cutNote()] : []),
    timeline(
      { tasks: top, groups, groupOf: (t) => t.projectId ?? "inbox", undated: false, label: "المخطط الزمني لكل المهام", empty: "لا مهام بتواريخ بعد. أضف لمهمة موعداً لتظهر هنا." },
      ctx,
    ),
  ];
}

/** A project's timeline, by section («بلا قسم» first, as on the board); undated tasks at the end of their section. */
export function projectTimeline({ project, sections, tasks }, ctx) {
  const groups = [{ id: UNSECTIONED, name: "بلا قسم" }, ...sections.slice().sort(byManualOrder).map((s) => ({ id: s.id, name: s.name }))];
  return timeline(
    {
      tasks: tasks.filter((t) => !t.parentId && isOpen(t)),
      groups,
      groupOf: (t) => t.sectionId ?? UNSECTIONED,
      undated: true,
      label: `المخطط الزمني لـ${project.name}`,
      empty: "لا مهام مفتوحة هنا.",
    },
    ctx,
  );
}

// ——— The timeline ———

/**
 * `ctx`: { primary, today, me, taskItem, openTask, canEditTask, announce, showError, errorText,
 * markLocalChange, render } from main.js.
 */
function timeline({ tasks, groups, groupOf, undated, label, empty }, ctx) {
  const root = h("div", { className: "timeline" });
  const weekStart = ctx.me?.settings?.weekStart ?? 0;
  let range = null;
  let scroller = null;

  const rtl = () => getComputedStyle(root).direction === "rtl";

  const memoryKey = () => `${label}|${prefs.zoom}`;

  function paint({ keepScroll = false, focus = null } = {}) {
    const rows = groupRows(tasks, groups, groupOf, { undated });
    const previous = keepScroll && range && scroller ? { from: range.from, logical: logicalScroll() } : null;
    range = timelineRange(tasks.map(taskSpan), ctx.today, { zoom: prefs.zoom, weekStart });

    if (rows.length === 0) {
      root.replaceChildren(toolbar(), h("p", { className: "body muted empty" }, empty));
      scroller = null;
      return;
    }
    const sheet = h("div", { className: `tl-sheet tl-zoom-${prefs.zoom}` });
    sheet.style.setProperty("--tl-days", String(range.days));
    sheet.append(head(), body(rows));
    scroller = h("div", { className: "tl-scroll", role: "region", "aria-label": label, tabindex: "0" }, sheet);
    scroller.addEventListener("scroll", () => scrolled.set(memoryKey(), { from: range.from, logical: logicalScroll() }), { passive: true });
    root.replaceChildren(toolbar(), scroller);

    // After a change here: stay where the person was. On opening (or a live reload): where they
    // last left this timeline, or today.
    const back = previous ?? scrolled.get(memoryKey());
    if (previous) restore(previous);
    else requestAnimationFrame(() => (back ? restore(back) : scrollToToday()));
    if (focus) root.querySelector(focus)?.focus();
  }

  const logicalScroll = () => (rtl() ? -scroller.scrollLeft : scroller.scrollLeft);

  /** Scrolls back to a saved position; days added before its first day push everything toward the end. */
  function restore({ from, logical }) {
    if (!scroller?.isConnected) return;
    const next = logical + dayDiff(range.from, from) * (trackWidth() / range.days);
    scroller.scrollLeft = rtl() ? -next : next;
  }

  const trackWidth = () => root.querySelector(".tl-scale")?.getBoundingClientRect().width ?? 0;

  function scrollToToday() {
    if (!scroller?.isConnected || !range) return;
    const label = root.querySelector(".tl-corner")?.getBoundingClientRect().width ?? 0;
    scroller.scrollLeft = scrollFor(dayDiff(range.from, ctx.today), {
      dayWidth: trackWidth() / range.days,
      labelWidth: label,
      viewport: scroller.clientWidth,
      rtl: rtl(),
    });
  }

  // ——— Zoom and «اليوم» ———

  function toolbar() {
    const zoom = h(
      "div",
      { className: "segmented", role: "group", "aria-label": "مقياس المخطط" },
      [
        ["day", "أيام"],
        ["week", "أسابيع"],
      ].map(([value, text]) => {
        const b = h("button", { type: "button", className: "segment callout", "aria-pressed": String(prefs.zoom === value) }, text);
        b.addEventListener("click", () => {
          if (prefs.zoom === value) return;
          saveZoom(value);
          paint({ focus: ".tl-toolbar .segment[aria-pressed='true']" });
        });
        return b;
      }),
    );
    const today = Button({ variant: "secondary" }, "اليوم");
    today.addEventListener("click", scrollToToday);
    return h(
      "div",
      { className: "tl-toolbar" },
      zoom,
      today,
      h("p", { className: "caption muted tl-hint" }, "اسحب الشريط لتغيير موعده، أو أحد طرفيه لتغيير المدة. «تغيير المدة…» يفعل ذلك من لوحة المفاتيح."),
    );
  }

  // ——— The scale: months in both calendars, then days or weeks ———

  function place(el, start, length) {
    el.style.setProperty("--tl-start", String(start));
    el.style.setProperty("--tl-len", String(length));
    return el;
  }

  function head() {
    const [primaryMonths, otherMonths] = headerMonths(range.from, range.days, ctx.primary);
    const monthRow = (segments, className) =>
      h("div", { className: `tl-scale-row ${className}` }, segments.map((s) => place(h("div", { className: "tl-month" }, h("span", null, s.label)), s.start, s.length)));
    const cells = scaleCells(range.from, range.days, { zoom: prefs.zoom, primary: ctx.primary, today: ctx.today });
    const cellRow = h(
      "div",
      { className: "tl-scale-row tl-cells" },
      cells.map((c) =>
        place(
          h("div", { className: `tl-cell${c.isToday ? " is-today" : ""}` }, h("span", { className: "tl-cell-primary" }, c.label), c.secondary ? h("span", { className: "tl-cell-secondary" }, c.secondary) : null),
          c.start,
          c.length,
        ),
      ),
    );
    return h(
      "div",
      { className: "tl-head" },
      h("div", { className: "tl-corner caption muted" }, "المهمة"),
      // The scale repeats what each row's «تغيير المدة…» says in words, so screen readers skip it.
      h("div", { className: "tl-scale caption", "aria-hidden": "true" }, monthRow(primaryMonths, "tl-months"), monthRow(otherMonths, "tl-months tl-months-other"), cellRow),
    );
  }

  function body(rows) {
    const cells = scaleCells(range.from, range.days, { zoom: prefs.zoom, primary: ctx.primary, today: ctx.today });
    const grid = h("div", { className: "tl-grid", "aria-hidden": "true" }, cells.map((c) => place(h("div", { className: `tl-grid-cell${c.isToday ? " is-today" : ""}` }), c.start, c.length)));
    const todayIndex = dayDiff(range.from, ctx.today);
    if (todayIndex >= 0 && todayIndex < range.days) grid.append(place(h("div", { className: "tl-today" }), todayIndex, 1));
    const out = h("div", { className: "tl-body" }, grid);
    for (const group of rows) {
      const titleId = `tl-group-${group.id}`;
      const list = h("ul", { className: "tl-rows", role: "list", "aria-labelledby": titleId });
      for (const task of group.tasks) list.append(row(task));
      out.append(h("section", { className: "tl-group", "aria-labelledby": titleId }, h("h2", { className: "headline tl-group-title", id: titleId }, h("span", { className: "tl-group-name" }, group.name)), list));
    }
    return out;
  }

  // ——— A row: the task, «تغيير المدة…», and its bar ———

  function row(task) {
    const li = ctx.taskItem(task, { showDate: false, showProject: false, leaveWhenDone: false });
    li.classList.add("tl-row");
    li.dataset.taskId = task.id;
    const taskRow = li.firstElementChild;
    taskRow?.classList.add("zm-task-compact");
    const span = taskSpan(task);
    const labelBox = h("div", { className: "tl-label" }, taskRow);
    const editable = ctx.canEditTask(task);
    if (editable) {
      const text = span ? "تغيير المدة…" : "تحديد المدة…";
      const change = h(
        "button",
        { type: "button", className: "card-move caption tl-change", "aria-haspopup": "dialog", "aria-label": `${text} «${task.title}»، ${spanText(span, ctx)}` },
        text,
      );
      change.addEventListener("click", () =>
        openDurationDialog(task, ctx, (saved) => {
          paint({ keepScroll: true, focus: `[data-task-id="${CSS.escape(task.id)}"] .tl-change` });
          ctx.onChanged?.(saved); // the same task open beside the timeline follows
        }),
      );
      labelBox.append(change);
    } else {
      labelBox.append(h("p", { className: "caption muted tl-span-text" }, spanText(span, ctx)));
    }
    const track = h("div", { className: "tl-track" });
    if (span) track.append(bar(task, span, editable, track));
    li.replaceChildren(labelBox, track);
    return li;
  }

  function bar(task, span, editable, track) {
    const { start, length } = barPlace(span, range.from);
    const el = place(h("div", { className: `span-bar tl-bar${priorityClass(task)}`, "aria-hidden": "true", title: `${task.title}، ${spanText(span, ctx)}` }), start, length);
    el.append(h("span", { className: "span-bar-title caption" }, task.title));
    // A day in the day zoom, or under a week in the week zoom, leaves no room for the title.
    const markShort = (days) => el.classList.toggle("is-short", days < (prefs.zoom === "week" ? 7 : 2));
    markShort(length);
    if (!editable) {
      el.addEventListener("click", () => ctx.openTask?.(task));
      return el;
    }
    el.classList.add("is-editable");
    el.prepend(h("span", { className: "tl-handle tl-handle-start" }));
    el.append(h("span", { className: "tl-handle tl-handle-end" }));

    let drag = null;
    el.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || drag) return;
      const mode = event.target.closest(".tl-handle-start") ? "start" : event.target.closest(".tl-handle-end") ? "end" : "move";
      drag = { mode, startX: event.clientX, delta: 0, moved: false, next: span, dayWidth: track.getBoundingClientRect().width / range.days, rtl: rtl(), id: event.pointerId };
      el.setPointerCapture(event.pointerId);
      event.preventDefault();
    });
    el.addEventListener("pointermove", (event) => {
      if (!drag || event.pointerId !== drag.id) return;
      if (!drag.moved && Math.abs(event.clientX - drag.startX) < TAP_SLOP) return;
      if (!drag.moved) {
        drag.moved = true;
        el.classList.add("is-dragging");
        document.body.classList.add("is-dragging");
      }
      const delta = pointerDelta(drag.startX, event.clientX, drag);
      if (delta === drag.delta) return;
      drag.delta = delta;
      drag.next = dragSpan(span, drag.mode, delta);
      const at = barPlace(drag.next, range.from);
      place(el, at.start, at.length);
      markShort(at.length);
      el.title = spanText(drag.next, ctx);
    });
    const finish = (event, cancelled) => {
      if (!drag || event.pointerId !== drag.id) return;
      const { moved, next } = drag;
      drag = null;
      el.classList.remove("is-dragging");
      document.body.classList.remove("is-dragging");
      if (el.hasPointerCapture?.(event.pointerId)) el.releasePointerCapture(event.pointerId);
      if (cancelled) {
        place(el, start, length);
        markShort(length);
        return;
      }
      if (!moved) return ctx.openTask?.(task);
      saveSpan(task, next);
    };
    el.addEventListener("pointerup", (event) => finish(event, false));
    el.addEventListener("pointercancel", (event) => finish(event, true));
    el.addEventListener("lostpointercapture", (event) => finish(event, true));
    return el;
  }

  async function saveSpan(task, span) {
    const patch = spanPatch(task, span);
    if (!patch) return paint({ keepScroll: true });
    const before = { dueDate: task.dueDate ?? null, startDate: task.startDate ?? null };
    Object.assign(task, patch);
    ctx.markLocalChange();
    paint({ keepScroll: true });
    try {
      Object.assign(task, await boardApi.patchTask(task.id, patch));
      ctx.announce(`«${task.title}»: ${spanText(taskSpan(task), ctx)}.`);
      paint({ keepScroll: true });
      ctx.onChanged?.(task); // the same task open beside the timeline follows
    } catch (error) {
      Object.assign(task, before);
      if (error.status !== 401) ctx.showError(error);
      paint({ keepScroll: true });
    }
  }

  paint();
  return root;
}

/** The bar's priority stripe; the priority is also in the task's row (its flag and hidden text). */
export function priorityClass(task) {
  return { 1: " is-low", 2: " is-medium", 3: " is-high" }[task.priority] ?? "";
}
