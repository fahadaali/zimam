// #/calendar, as in the Apple app (CalendarView.swift): a month or a week in Hijri (Umm al-Qura)
// or Gregorian, each day with the other calendar's day under it and dots for its open tasks; the
// selected day's tasks under the month; «اليوم» to come back. A task dragged onto another day moves
// there keeping its time or prayer anchor (only `dueDate` changes); «نقل إلى…» does the same from
// the keyboard with a date field. Arrow keys move through the month grid (right is back a day in
// Arabic), Page Up and Page Down through months.
// Plain DOM through h() and textContent; nothing here parses HTML.
import { Button, h } from "./lib/components.js";
import { addDays, dayHeading, dualDate, isIsoDate, relativeDay, weekdayName } from "./lib/dates.js";
import { boardApi } from "./lib/feature-api.js";
import { addMonths, keyMove, monthDays, monthTitle, rangeTitle, tasksByDay, weekDays, weekdayHeaders } from "./lib/calendar.js";
import { arabicNumber } from "./lib/numbers.js";
import { taskCount } from "./lib/tasks.js";

/** Kept across renders (and live reloads) for this page's life. */
const view = { mode: "month", kind: null, selected: null };

/** The selected day, so «إضافة مهمة» from the calendar starts on it. */
export function calendarSelectedDay() {
  return view.selected;
}

let draggedId = null;

/**
 * The view. `ctx`: { primary, today, me, taskItem(task, options), announce, showError, render,
 * markLocalChange, canEditTask(task) } from main.js. Returns its nodes, like the other views.
 */
export async function viewCalendar(ctx) {
  const root = h("div", { className: "calendar" });
  const weekStart = ctx.me?.settings?.weekStart ?? 0;
  view.selected ??= ctx.today;
  let data = { from: null, to: null, byDay: {}, tasks: [] };
  let painting = 0;

  const kind = () => view.kind ?? ctx.primary;
  const days = () => (view.mode === "month" ? monthDays(view.selected, { kind: kind(), weekStart }) : weekDays(view.selected, { kind: kind(), weekStart }));

  async function load(from, to) {
    const { tasks } = await boardApi.tasks({ status: "open", dueFrom: from, dueTo: to });
    data = { from, to, tasks, byDay: tasksByDay(tasks) };
  }

  async function paint(focus) {
    const id = ++painting;
    const shown = days();
    const from = shown[0].day;
    const to = shown[shown.length - 1].day;
    if (data.from !== from || data.to !== to) {
      try {
        await load(from, to);
      } catch (error) {
        if (error.status === 401) return;
        ctx.showError(error);
      }
    }
    if (id !== painting) return;
    root.replaceChildren(header(shown), ...(view.mode === "month" ? [monthGrid(shown), selectedDay()] : [weekColumns(shown)]));
    if (focus) root.querySelector(focus)?.focus();
  }

  const select = (day, focus = ".cal-day[tabindex='0']") => {
    view.selected = day;
    paint(focus);
  };

  // ——— Header: title, month or week, Hijri or Gregorian, previous and next, «اليوم» ———

  function segmented(label, options, current, onPick) {
    return h(
      "div",
      { className: "segmented", role: "group", "aria-label": label },
      options.map(([value, text]) => {
        const b = h("button", { type: "button", className: "segment callout", "aria-pressed": String(current === value) }, text);
        b.addEventListener("click", () => onPick(value));
        return b;
      }),
    );
  }

  function header(shown) {
    const title =
      view.mode === "month" ? monthTitle(view.selected, kind()) : rangeTitle(shown[0].day, shown[shown.length - 1].day, kind());
    const step = (direction) => {
      const label = view.mode === "month" ? (direction < 0 ? "الشهر السابق" : "الشهر التالي") : direction < 0 ? "الأسبوع السابق" : "الأسبوع التالي";
      const b = h("button", { type: "button", className: "icon-button", "aria-label": label }, chevron(direction));
      b.addEventListener("click", () => {
        view.selected = view.mode === "month" ? addMonths(view.selected, direction, kind()) : addDays(view.selected, 7 * direction);
        paint(`.icon-button[aria-label="${label}"]`);
      });
      return b;
    };
    const today = Button({ variant: "secondary", "aria-describedby": "cal-today-hint" }, "اليوم");
    today.addEventListener("click", () => select(ctx.today, ".cal-today-button"));
    today.classList.add("cal-today-button");
    return h(
      "header",
      { className: "view-header calendar-header" },
      h("h1", { className: "display view-title", tabindex: "-1" }, "التقويم"),
      h(
        "div",
        { className: "calendar-controls" },
        segmented("العرض", [["month", "شهر"], ["week", "أسبوع"]], view.mode, (mode) => {
          view.mode = mode;
          paint(`.segment[aria-pressed="true"]`);
        }),
        segmented("التقويم", [["hijri", "هجري"], ["gregorian", "ميلادي"]], kind(), (value) => {
          view.kind = value;
          paint(`.calendar-controls .segmented:nth-child(2) .segment[aria-pressed="true"]`);
        }),
        today,
        h("span", { className: "visually-hidden", id: "cal-today-hint" }, "يعود إلى اليوم في التقويم"),
      ),
      h("div", { className: "calendar-period" }, h("p", { className: "headline period-title", "aria-live": "polite" }, title), step(-1), step(1)),
    );
  }

  // ——— The month ———

  function monthGrid(shown) {
    const heads = weekdayHeaders(weekStart);
    const table = h(
      "table",
      { className: "cal-grid", "aria-label": monthTitle(view.selected, kind()) },
      h("thead", null, h("tr", null, heads.map((d) => h("th", { scope: "col", className: "caption muted" }, h("abbr", { title: d.long }, d.short))))),
    );
    const body = h("tbody");
    for (let row = 0; row < shown.length / 7; row++) {
      body.append(h("tr", null, shown.slice(row * 7, row * 7 + 7).map((cell) => h("td", null, dayCell(cell)))));
    }
    table.append(body);
    table.addEventListener("keydown", (event) => {
      if (!event.target.classList?.contains("cal-day")) return;
      const next = keyMove(view.selected, event.key, { kind: kind(), weekStart, rtl: getComputedStyle(table).direction === "rtl" });
      if (!next) return;
      event.preventDefault();
      select(next);
    });
    return table;
  }

  function dayCell(cell) {
    const tasks = data.byDay[cell.day] ?? [];
    const selected = cell.day === view.selected;
    const isToday = cell.day === ctx.today;
    const label = `${weekdayName(cell.day)}، ${dualDate(cell.day, { primary: kind(), today: ctx.today })}، ${tasks.length ? taskCount(tasks.length) : "بلا مهام"}`;
    const dots = h("span", { className: "cal-dots", "aria-hidden": "true" }, tasks.slice(0, 3).map(() => h("span", { className: "cal-dot" })), tasks.length > 3 ? h("span", { className: "cal-more" }, "+") : null);
    const button = h(
      "button",
      {
        type: "button",
        className: ["cal-day", cell.inPeriod ? null : "is-outside", isToday ? "is-today" : null].filter(Boolean).join(" "),
        tabindex: selected ? "0" : "-1",
        "aria-pressed": String(selected),
        "aria-current": isToday ? "date" : null,
        "aria-label": label,
        dataset: { day: cell.day },
      },
      h("span", { className: "cal-primary", "aria-hidden": "true" }, arabicNumber(cell.primaryDay)),
      h("span", { className: "cal-secondary caption", "aria-hidden": "true" }, arabicNumber(cell.secondaryDay)),
      dots,
    );
    button.addEventListener("click", () => select(cell.day));
    dropDay(button, cell.day);
    return button;
  }

  function selectedDay() {
    const day = view.selected;
    const heading = dayHeading(day, { today: ctx.today, primary: kind() });
    const tasks = data.byDay[day] ?? [];
    const list = h("ul", { className: "task-list", role: "list", "aria-label": `مهام ${heading.title}` });
    for (const task of tasks) list.append(calendarItem(task));
    const section = h(
      "section",
      { className: "list-section cal-selected", "aria-labelledby": "cal-day-title" },
      h("hgroup", { className: "day-heading" }, h("h2", { className: "headline", id: "cal-day-title" }, heading.title), h("p", { className: "caption muted" }, heading.subtitle)),
      tasks.length ? list : h("p", { className: "body muted empty" }, "لا مهام في هذا اليوم."),
    );
    dropDay(section, day);
    return section;
  }

  // ——— The week ———

  function weekColumns(shown) {
    const list = h("ol", { className: "week", role: "list" });
    for (const cell of shown) {
      const tasks = data.byDay[cell.day] ?? [];
      const word = relativeDay(cell.day, ctx.today);
      const titleId = `week-${cell.day}`;
      const head = h(
        "button",
        { type: "button", className: `week-head${cell.day === ctx.today ? " is-today" : ""}`, id: `${titleId}-head`, "aria-pressed": String(cell.day === view.selected) },
        h("span", { className: "headline", id: titleId }, word === "اليوم" || word === "غداً" ? `${word}، ${weekdayName(cell.day)}` : weekdayName(cell.day)),
        h("span", { className: "caption muted" }, dualDate(cell.day, { primary: kind(), today: ctx.today })),
      );
      head.addEventListener("click", () => {
        view.selected = cell.day;
        paint(`#${CSS.escape(`${titleId}-head`)}`);
      });
      const items = h("ul", { className: "task-list week-tasks", role: "list", "aria-labelledby": titleId });
      for (const task of tasks) items.append(calendarItem(task, true));
      const day = h("li", { className: "week-day" }, head, tasks.length ? items : h("p", { className: "caption muted week-empty" }, "لا مهام"));
      dropDay(day, cell.day);
      list.append(day);
    }
    return list;
  }

  // ——— Tasks: drag to another day, or «نقل إلى…» ———

  function calendarItem(task, compact = false) {
    const li = ctx.taskItem(task, { showDate: false, showProject: !compact, leaveWhenDone: true });
    if (compact) li.firstElementChild?.classList.add("zm-task-compact");
    if (!ctx.canEditTask(task)) return li;
    li.draggable = true;
    li.addEventListener("dragstart", (event) => {
      draggedId = task.id;
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", task.title);
      li.firstElementChild?.classList.add("zm-task-lifted");
      document.body.classList.add("is-dragging");
    });
    li.addEventListener("dragend", () => {
      draggedId = null;
      li.firstElementChild?.classList.remove("zm-task-lifted");
      document.body.classList.remove("is-dragging");
      root.querySelectorAll(".is-target").forEach((el) => el.classList.remove("is-target"));
    });
    li.append(moveToDay(task));
    return li;
  }

  function moveToDay(task) {
    const fieldId = `move-day-${task.id}`;
    const toggle = h("button", { type: "button", className: "card-move caption", "aria-expanded": "false", "aria-label": `نقل «${task.title}» إلى يوم آخر` }, "نقل إلى…");
    const input = h("input", { className: "input callout", id: fieldId, type: "date", value: task.dueDate ?? "" });
    const preview = h("p", { className: "caption muted", "aria-live": "polite" });
    const cancel = Button({ variant: "quiet" }, "إلغاء");
    const form = h(
      "form",
      { className: "column-form", hidden: true, novalidate: true },
      h("label", { className: "caption muted", for: fieldId }, "اليوم الجديد"),
      input,
      preview,
      h("div", { className: "sheet-actions" }, Button({ variant: "secondary", type: "submit" }, "نقل"), cancel),
    );
    const update = () => (preview.textContent = isIsoDate(input.value) ? dualDate(input.value, { primary: kind(), today: ctx.today }) : "");
    input.addEventListener("input", update);
    toggle.addEventListener("click", () => {
      form.hidden = !form.hidden;
      toggle.setAttribute("aria-expanded", String(!form.hidden));
      if (!form.hidden) {
        update();
        input.focus();
      }
    });
    cancel.addEventListener("click", () => {
      form.hidden = true;
      toggle.setAttribute("aria-expanded", "false");
      toggle.focus();
    });
    form.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        cancel.click();
      }
    });
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (isIsoDate(input.value)) reschedule(task.id, input.value, true);
    });
    return h("div", { className: "card-tools" }, toggle, form);
  }

  function dropDay(el, day) {
    el.addEventListener("dragover", (event) => {
      if (!draggedId) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      el.classList.add("is-target");
    });
    el.addEventListener("dragleave", (event) => {
      if (!el.contains(event.relatedTarget)) el.classList.remove("is-target");
    });
    el.addEventListener("drop", (event) => {
      if (!draggedId) return;
      event.preventDefault();
      event.stopPropagation();
      const id = draggedId;
      draggedId = null;
      document.body.classList.remove("is-dragging");
      reschedule(id, day, false);
    });
  }

  /** Moves a task to `day`; only its date changes, so its time or prayer anchor stays. */
  async function reschedule(id, day, follow) {
    const task = data.tasks.find((t) => t.id === id);
    if (!task || task.dueDate === day) return;
    const previous = task.dueDate;
    task.dueDate = day;
    data.byDay = tasksByDay(data.tasks);
    if (follow) view.selected = day;
    ctx.markLocalChange();
    const where = dualDate(day, { primary: kind(), today: ctx.today });
    await paint(follow ? `[data-day="${day}"]` : null);
    try {
      Object.assign(task, await boardApi.patchTask(id, { dueDate: day }));
      ctx.announce(`نُقلت إلى ${where}.`);
    } catch (error) {
      task.dueDate = previous;
      data.byDay = tasksByDay(data.tasks);
      if (error.status !== 401) ctx.showError(error);
      paint();
    }
  }

  await paint();
  return [root];
}

/** Back and forward chevrons; in Arabic «السابق» points right. */
function chevron(direction) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("width", "16");
  svg.setAttribute("height", "16");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("class", "zm-ico chevron");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  // Drawn for right-to-left: back points right, forward points left.
  path.setAttribute("d", direction < 0 ? "M6 3l5 5-5 5" : "M10 3L5 8l5 5");
  for (const [k, v] of Object.entries({ fill: "none", stroke: "currentColor", "stroke-width": "1.8", "stroke-linecap": "round", "stroke-linejoin": "round" })) path.setAttribute(k, v);
  svg.append(path);
  return svg;
}
