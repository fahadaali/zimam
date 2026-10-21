// «نقل إلى مشروع…» on the web (MoveToProjectSheet.swift and TaskListItem's context menu):
// - showTaskMenu(): the small menu a task row opens on right-click, the Menu key or Shift+F10, with
//   one item, «نقل إلى مشروع…».
// - openMoveSheet(): the sheet itself. «صندوق المهام», then each project the person edits with its
//   sections under it; the task's current place is ticked and only closes the sheet. Choosing
//   another place moves the task there at once (with its subtasks), as a drop on the sidebar does.
// Plain DOM through h() and textContent; nothing here parses HTML. Styles in editor.css.
import { Button, h } from "./lib/components.js";
import { boardApi } from "./lib/feature-api.js";
import { icon } from "./lib/icons.js";
import { knownSections, movableProjects, moveDestinations } from "./lib/move.js";

/** At most this many project requests at once when a project's sections are not known yet. */
const SECTION_FETCHES = 4;

const ICONS = { inbox: "inbox", project: "folder", section: "section" };

/**
 * `ctx` (from main.js): { projects() → the projects as GET /v1/projects gives them,
 * move(taskId, { projectId, sectionId, label }), returnFocus? (the element to focus when the
 * sheet closes without a move) }.
 */
export function openMoveSheet(task, ctx) {
  document.getElementById("move-dialog")?.remove();
  const cancel = Button({ variant: "quiet" }, "إلغاء");
  const body = h("div", { className: "move-body" });
  const dialog = h(
    "dialog",
    { className: "sheet move-sheet", id: "move-dialog", "aria-labelledby": "move-title", "aria-describedby": "move-task" },
    h(
      "div",
      { className: "sheet-form" },
      h("div", { className: "sheet-bar" }, cancel, h("h2", { className: "headline sheet-bar-title", id: "move-title" }, "نقل إلى مشروع…"), h("span")),
      h("p", { className: "callout muted move-task", id: "move-task" }, task.title),
      body,
    ),
  );
  let moved = false;
  cancel.addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => {
    dialog.remove();
    if (!moved && ctx.returnFocus?.isConnected) ctx.returnFocus.focus();
  });

  const sections = knownSections(ctx.projects());

  function row(place) {
    const button = h(
      "button",
      {
        type: "button",
        className: `move-row body${place.kind === "section" ? " is-section" : ""}`,
        "aria-current": place.current ? "true" : null,
        "aria-label": place.spoken !== place.name ? place.spoken : null,
        dataset: { place: `${place.projectId ?? ""}/${place.sectionId ?? ""}` },
      },
      icon(ICONS[place.kind]),
      h("span", { className: "move-name" }, place.name),
      place.current ? icon("check", { size: "sm" }) : null,
    );
    button.addEventListener("click", () => {
      if (place.current) {
        dialog.close();
        return;
      }
      moved = true;
      dialog.close();
      ctx.move(task.id, { projectId: place.projectId, sectionId: place.sectionId, label: place.label });
    });
    return h("li", null, button);
  }

  function draw() {
    // Redrawn once late sections arrive: the focus stays on the same place.
    const focused = dialog.contains(document.activeElement) ? document.activeElement.dataset?.place : null;
    const places = moveDestinations(task, ctx.projects(), sections);
    const [inbox, ...rest] = places;
    body.replaceChildren(
      h("ul", { className: "form-card move-list", role: "list" }, row(inbox)),
      h(
        "section",
        { className: "move-projects", "aria-labelledby": "move-projects-title" },
        h("h3", { className: "caption muted form-section-title", id: "move-projects-title" }, "المشاريع"),
        rest.length
          ? h("ul", { className: "form-card move-list", role: "list" }, rest.map(row))
          : h("p", { className: "callout muted move-empty" }, "لا مشاريع بعد."),
      ),
    );
    if (focused != null) body.querySelector(`[data-place="${CSS.escape(focused)}"]`)?.focus();
  }

  document.body.append(dialog);
  draw();
  dialog.showModal();
  // Start on the current place, as a picker does.
  body.querySelector('[aria-current="true"]')?.focus();

  // Projects whose sections GET /v1/projects did not carry: read them now, then redraw once.
  const missing = movableProjects(ctx.projects())
    .filter((p) => !sections.has(p.id))
    .map((p) => p.id);
  if (missing.length) {
    const worker = async () => {
      while (missing.length) {
        const id = missing.shift();
        try {
          const detail = await boardApi.project(id);
          sections.set(id, detail.sections ?? detail.project?.sections ?? []);
        } catch {
          /* listed without its sections; the project itself is still a place */
        }
      }
    };
    Promise.all(Array.from({ length: SECTION_FETCHES }, worker)).then(() => {
      if (dialog.isConnected) draw();
    });
  }
  return dialog;
}

let menu = null;
let lastMenuKey = -Infinity;
// The Menu key and Shift+F10 open the menu with no pointer position; noted here to place it under the row.
document.addEventListener(
  "keydown",
  (event) => {
    if (event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey)) lastMenuKey = performance.now();
  },
  true,
);
let menuTask = null;
let menuCtx = null;
let choosing = false;

/** The one context menu, made once and reused by every row. */
function taskMenu() {
  if (menu) return menu;
  const move = h(
    "button",
    { type: "button", className: "menu-row callout", "aria-haspopup": "dialog" },
    icon("folder"),
    "نقل إلى مشروع…",
  );
  menu = h("div", { className: "account-menu task-menu", id: "task-menu", popover: "auto", "aria-label": "خيارات المهمة" }, h("ul", { className: "menu-list", role: "list" }, h("li", null, move)));
  move.addEventListener("click", () => {
    const task = menuTask;
    const ctx = menuCtx;
    choosing = true; // the toggle event comes later, after the sheet has the focus
    menu.hidePopover();
    if (task) openMoveSheet(task, ctx);
  });
  menu.addEventListener("keydown", (event) => {
    // Tab out of a one-item menu closes it, as Escape does (light dismiss).
    if (event.key === "Tab") menu.hidePopover();
  });
  menu.addEventListener("toggle", (event) => {
    if (event.newState !== "closed") return;
    if (choosing) {
      choosing = false;
      return;
    }
    // Dismissed: back to the row it was opened from, when the focus would otherwise be lost.
    const active = document.activeElement;
    if ((!active || active === document.body || menu.contains(active)) && menuCtx?.returnFocus?.isConnected) menuCtx.returnFocus.focus();
  });
  document.body.append(menu);
  return menu;
}

/**
 * Opens the row's context menu at the pointer, or under the row when it came from the keyboard
 * (the Menu key or Shift+F10 give no pointer position). `ctx` is openMoveSheet's.
 */
export function showTaskMenu(event, task, ctx) {
  // On the Mac and Linux the menu event comes while the right button is still down; the popover
  // would take its release for a click outside and close at once, so it opens after the release.
  if (event.buttons & 2) {
    const point = { clientX: event.clientX, clientY: event.clientY, currentTarget: event.currentTarget, target: event.target };
    window.addEventListener("pointerup", () => setTimeout(() => openTaskMenu(point, task, ctx)), { once: true, capture: true });
    return;
  }
  openTaskMenu(event, task, ctx);
}

function openTaskMenu(event, task, ctx) {
  const el = taskMenu();
  menuTask = task;
  menuCtx = ctx;
  if (el.matches(":popover-open")) el.hidePopover();
  el.style.setProperty("--menu-top", "0px");
  el.style.setProperty("--menu-end", "0px");
  el.showPopover();

  const fromKeyboard = performance.now() - lastMenuKey < 500 || (event.clientX === 0 && event.clientY === 0);
  const anchor = (event.currentTarget ?? event.target).getBoundingClientRect();
  const rtl = document.documentElement.dir === "rtl";
  let x = event.clientX;
  let y = event.clientY;
  if (fromKeyboard) {
    x = rtl ? anchor.right : anchor.left;
    y = anchor.bottom;
  }
  const box = el.getBoundingClientRect();
  const gap = 8;
  // The menu opens toward the reading direction from the point (to its left in Arabic), and stays on screen.
  let left = rtl ? x - box.width : x;
  left = Math.min(Math.max(gap, left), window.innerWidth - box.width - gap);
  const top = Math.min(Math.max(gap, y), window.innerHeight - box.height - gap);
  el.style.setProperty("--menu-top", `${top}px`);
  el.style.setProperty("--menu-end", `${rtl ? left : window.innerWidth - left - box.width}px`);
  el.querySelector("button")?.focus();
}
