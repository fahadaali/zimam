// «المصفوفة» (#/matrix): open tasks in four quadrants, «مهم وعاجل» at the inline start (top right
// in Arabic), then «مهم», «عاجل» and «يوماً ما», as in the Apple app's widget. Each quadrant has
// its icon, title and count, then its first rows (completion circle, title, due chip) and
// «+n أخرى» for the rest. A task completes in place; it moves to another quadrant by drag and drop,
// or from its «نقل إلى» menu with the keyboard. The rules (what a move changes, and that leaving
// the urgent quadrants clears the due date only after confirming) are in lib/matrix.js.
// Plain DOM through h() and textContent; nothing here parses HTML.
import { Button, h } from "./lib/components.js";
import { dualDate } from "./lib/dates.js";
import { boardApi } from "./lib/feature-api.js";
import { QUADRANTS, VISIBLE_ROWS, hiddenCount, moveToQuadrant, quadrant, quadrants, todayIn } from "./lib/matrix.js";
import { arabicNumber } from "./lib/numbers.js";
import { taskCount } from "./lib/tasks.js";

/** Expanded quadrants, kept across live reloads for this page's life. */
const expanded = new Set();

let dragged = null;

/** `ctx`: { me, primary, taskItem, canEditTask, announce, showError, markLocalChange, render }. */
export async function viewMatrix(ctx) {
  const today = todayIn(ctx.me?.settings?.timeZone);
  const { tasks } = await boardApi.tasks({ status: "open" });
  const top = tasks.filter((t) => !t.parentId);
  const root = h("div", { className: "matrix" });

  function paint(focus) {
    const groups = quadrants(top, today);
    root.replaceChildren(...QUADRANTS.map((q) => quadrantView(q, groups[q.key])));
    if (focus) root.querySelector(focus)?.focus();
  }

  // ——— A quadrant ———

  function quadrantView(q, list) {
    const titleId = `quad-${q.key}`;
    const isExpanded = expanded.has(q.key);
    const shown = isExpanded ? list : list.slice(0, VISIBLE_ROWS);
    const more = hiddenCount(list.length, isExpanded);
    const rows = h("ul", { className: "task-list matrix-list", role: "list", "aria-labelledby": titleId });
    for (const task of shown) rows.append(row(task, q));
    const section = h(
      "section",
      { className: `matrix-quad quad-${q.key}`, "aria-labelledby": titleId, dataset: { quadrant: q.key } },
      h(
        "header",
        { className: "matrix-head" },
        quadIcon(q.key),
        h("h2", { className: "headline matrix-title", id: titleId }, q.title),
        h("span", { className: "matrix-count caption" }, h("span", { "aria-hidden": "true" }, arabicNumber(list.length)), h("span", { className: "zm-sr" }, `، ${taskCount(list.length)}`)),
      ),
      list.length ? rows : h("p", { className: "caption muted matrix-empty" }, "لا مهام هنا."),
    );
    if (more > 0 || (isExpanded && list.length > VISIBLE_ROWS)) {
      const toggle = h("button", { type: "button", className: "card-move caption matrix-more", "aria-expanded": String(isExpanded) }, isExpanded ? "عرض أقل" : `+${arabicNumber(more)} أخرى`);
      toggle.addEventListener("click", () => {
        if (isExpanded) expanded.delete(q.key);
        else expanded.add(q.key);
        paint(`[data-quadrant="${q.key}"] .matrix-more`);
      });
      section.append(toggle);
    }
    dropTarget(section, q);
    return section;
  }

  function row(task, q) {
    const li = ctx.taskItem(task, { showDate: true, showProject: false, leaveWhenDone: true });
    li.dataset.taskId = task.id;
    li.firstElementChild?.classList.add("zm-task-compact");
    if (!ctx.canEditTask(task)) return li;
    li.draggable = true;
    li.addEventListener("dragstart", (event) => {
      dragged = task.id;
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", task.title);
      li.firstElementChild?.classList.add("zm-task-lifted");
      document.body.classList.add("is-dragging");
    });
    li.addEventListener("dragend", () => {
      dragged = null;
      li.firstElementChild?.classList.remove("zm-task-lifted");
      document.body.classList.remove("is-dragging");
      root.querySelectorAll(".is-target").forEach((el) => el.classList.remove("is-target"));
    });
    li.append(moveMenu(task, q));
    return li;
  }

  function dropTarget(section, q) {
    section.addEventListener("dragover", (event) => {
      if (!dragged) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      section.classList.add("is-target");
    });
    section.addEventListener("dragleave", (event) => {
      if (!section.contains(event.relatedTarget)) section.classList.remove("is-target");
    });
    section.addEventListener("drop", (event) => {
      if (!dragged) return;
      event.preventDefault();
      const task = top.find((t) => t.id === dragged);
      dragged = null;
      document.body.classList.remove("is-dragging");
      section.classList.remove("is-target");
      if (task) move(task, q.key);
    });
  }

  // ——— «نقل إلى»: the keyboard's way between quadrants ———

  function moveMenu(task, current) {
    const menuId = `quad-move-${task.id}`;
    const toggle = h(
      "button",
      { type: "button", className: "card-move caption", "aria-expanded": "false", "aria-controls": menuId, "aria-haspopup": "true", "aria-label": `نقل إلى ربع آخر: «${task.title}»` },
      "نقل إلى",
    );
    const items = QUADRANTS.filter((q) => q.key !== current.key).map((q) => {
      const b = h("button", { type: "button", role: "menuitem", className: "menu-item callout" }, q.title);
      b.addEventListener("click", () => {
        close();
        move(task, q.key);
      });
      return b;
    });
    const menu = h("div", { className: "card-menu", id: menuId, role: "menu", "aria-label": `نقل «${task.title}» إلى`, hidden: true }, items);
    const open = () => {
      menu.hidden = false;
      toggle.setAttribute("aria-expanded", "true");
      items[0]?.focus();
    };
    const close = (focusToggle = false) => {
      menu.hidden = true;
      toggle.setAttribute("aria-expanded", "false");
      if (focusToggle) toggle.focus();
    };
    toggle.addEventListener("click", () => (menu.hidden ? open() : close()));
    menu.addEventListener("keydown", (event) => {
      const at = items.indexOf(document.activeElement);
      const go = { ArrowDown: at + 1, ArrowUp: at - 1, Home: 0, End: items.length - 1 }[event.key];
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        close(true);
      } else if (go !== undefined) {
        event.preventDefault();
        items[(go + items.length) % items.length]?.focus();
      }
    });
    const wrap = h("div", { className: "card-tools" }, toggle, menu);
    wrap.addEventListener("focusout", (event) => {
      if (!menu.hidden && !wrap.contains(event.relatedTarget)) close();
    });
    return wrap;
  }

  // ——— Moving ———

  async function move(task, to) {
    const { patch, clearsDueDate } = moveToQuadrant(task, to, today);
    const target = quadrant(to);
    const focus = `[data-task-id="${CSS.escape(task.id)}"] .card-move`;
    if (Object.keys(patch).length === 0) return;
    if (clearsDueDate && !(await confirmClear(task, target))) {
      root.querySelector(focus)?.focus();
      return;
    }
    const before = Object.fromEntries(Object.keys(patch).map((k) => [k, task[k] ?? null]));
    Object.assign(task, patch);
    ctx.markLocalChange();
    // The quadrant it lands in opens far enough to show it.
    const landed = quadrants(top, today)[to];
    if (landed.indexOf(task) >= VISIBLE_ROWS) expanded.add(to);
    paint(focus);
    try {
      Object.assign(task, await boardApi.patchTask(task.id, patch));
      ctx.announce(`نُقلت إلى «${target.title}».`);
    } catch (error) {
      Object.assign(task, before);
      if (error.status !== 401) ctx.showError(error);
      paint(focus);
    }
  }

  /** Leaving the urgent quadrants clears the due date: only when the person says so. */
  function confirmClear(task, target) {
    let dialog = document.getElementById("matrix-confirm");
    if (!dialog) {
      dialog = h("dialog", { className: "sheet", id: "matrix-confirm", "aria-labelledby": "matrix-confirm-title", "aria-describedby": "matrix-confirm-text" });
      document.body.append(dialog);
    }
    const due = task.dueDate ? dualDate(task.dueDate, { primary: ctx.primary, today }) : "";
    const yes = Button({ variant: "secondary", className: "danger" }, "إزالة الموعد ونقلها");
    const no = Button({ variant: "quiet" }, "إلغاء");
    dialog.replaceChildren(
      h(
        "div",
        { className: "sheet-form" },
        h("h2", { className: "title", id: "matrix-confirm-title" }, `نقل إلى «${target.title}»`),
        h("p", { className: "callout", id: "matrix-confirm-text" }, `«${task.title}» عاجلة لأن موعدها ${due}. نقلها إلى «${target.title}» يزيل موعدها${task.startDate ? " وتاريخ بدايتها" : ""}.`),
        h("div", { className: "sheet-actions" }, yes, no),
      ),
    );
    return new Promise((resolve) => {
      let answer = false;
      yes.addEventListener("click", () => {
        answer = true;
        dialog.close();
      });
      no.addEventListener("click", () => dialog.close());
      dialog.addEventListener("close", () => resolve(answer), { once: true });
      dialog.showModal();
      no.focus();
    });
  }

  paint();
  return [
    h(
      "header",
      { className: "view-header" },
      h("h1", { className: "display view-title", tabindex: "-1" }, "المصفوفة"),
      h("p", { className: "callout muted" }, "المهم: أولوية متوسطة أو عالية. العاجل: موعده اليوم أو غداً أو فات."),
    ),
    root,
  ];
}

// ——— Icons: drawn like lib/components.js icons, 1.6px strokes in the text's colour ———

const SVG = "http://www.w3.org/2000/svg";
const ICON_PATHS = {
  // A flame: important and urgent.
  "urgent-important": "M8 14.5c-2.6 0-4.5-1.9-4.5-4.4 0-3.3 3.4-4.6 3.4-8.6 2.4 1.4 3.4 3.6 3.2 5.6.8-.4 1.3-1.2 1.5-2 1 1.1 1.4 2.5 1.4 3.8 0 3.2-2.2 5.6-5 5.6z",
  // A flag: important.
  important: "M4 14V2.5M4 3h7.5l-1.8 2.75L11.5 8.5H4",
  // A bolt: urgent.
  urgent: "M9 1.5L3.5 9H8l-1 5.5L12.5 7H8l1-5.5z",
  // Lines: some day.
  someday: "M3 4.5h10M3 8h10M3 11.5h10",
};

function quadIcon(key) {
  const root = document.createElementNS(SVG, "svg");
  for (const [k, v] of Object.entries({ viewBox: "0 0 16 16", width: "18", height: "18", "aria-hidden": "true", class: "zm-ico matrix-icon" })) root.setAttribute(k, v);
  const path = document.createElementNS(SVG, "path");
  for (const [k, v] of Object.entries({ d: ICON_PATHS[key], fill: "none", stroke: "currentColor", "stroke-width": "1.6", "stroke-linecap": "round", "stroke-linejoin": "round" })) path.setAttribute(k, v);
  root.append(path);
  return root;
}
