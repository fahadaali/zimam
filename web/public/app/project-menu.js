// «خيارات المشروع»: one menu for a project, opened from the «خيارات» button in its header, from a
// right-click (or the Menu key) on its row in the sidebar, and from the archived projects list.
// Owners and editors rename and archive; the owner alone deletes, after a question that names what
// goes with the project (lib/project-actions.js). Each action saves through the API, refreshes the
// project list and the sidebar, and says what happened in the live region.
import { api } from "./lib/api.js";
import { Button, h } from "./lib/components.js";
import { icon } from "./lib/icons.js";
import { announcement, ARCHIVE_NOTE, archiveLabel, DELETE_NOTE, deleteQuestion, projectErrorText, projectPermissions } from "./lib/project-actions.js";

let menu = null;
let current = null;
let lastMenuKey = -Infinity;
let choosing = false;

// The Menu key and Shift+F10 open a menu with no pointer position: it then sits under its row.
document.addEventListener(
  "keydown",
  (event) => {
    if (event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey)) lastMenuKey = performance.now();
  },
  true,
);

function row(iconName, label, onClick, danger = false) {
  const button = h("button", { type: "button", className: `menu-row callout${danger ? " danger" : ""}` }, icon(iconName), label);
  button.addEventListener("click", () => {
    const target = current;
    choosing = true;
    menu.hidePopover();
    if (target) onClick(target.project, target.ctx);
  });
  return h("li", null, button);
}

function projectMenu() {
  if (menu) return menu;
  menu = h("div", { className: "account-menu task-menu", id: "project-menu", popover: "auto", "aria-label": "خيارات المشروع" });
  menu.addEventListener("keydown", (event) => {
    const rows = [...menu.querySelectorAll("button")];
    const at = rows.indexOf(document.activeElement);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      rows[(at + (event.key === "ArrowDown" ? 1 : rows.length - 1)) % rows.length]?.focus();
    } else if (event.key === "Tab") menu.hidePopover();
  });
  menu.addEventListener("toggle", (event) => {
    if (event.newState !== "closed") return;
    if (choosing) {
      choosing = false;
      return;
    }
    const active = document.activeElement;
    if ((!active || active === document.body || menu.contains(active)) && current?.returnFocus?.isConnected) current.returnFocus.focus();
  });
  document.body.append(menu);
  return menu;
}

/** Whether the user may do anything to `project` from the menu. */
export function hasProjectActions(project) {
  const can = projectPermissions(project);
  return can.canRename || can.canArchive || can.canDelete;
}

/**
 * Opens the menu for `project`. `event` is a contextmenu event, or a click on the «خيارات» button
 * (the menu then sits under it). `ctx`: { announce, refreshProjects, onRemoved(project) }.
 */
export function showProjectMenu(event, project, ctx) {
  if (!hasProjectActions(project)) return;
  event.preventDefault?.();
  // On the Mac and Linux the menu event comes while the right button is still down (move-sheet.js).
  if (event.buttons & 2) {
    const point = { clientX: event.clientX, clientY: event.clientY, currentTarget: event.currentTarget, target: event.target, type: event.type };
    window.addEventListener("pointerup", () => setTimeout(() => openMenu(point, project, ctx)), { once: true, capture: true });
    return;
  }
  openMenu(event, project, ctx);
}

function openMenu(event, project, ctx) {
  const el = projectMenu();
  const can = projectPermissions(project);
  const source = event.currentTarget ?? event.target;
  current = { project, ctx, returnFocus: source };
  const rows = [];
  if (can.canRename) rows.push(row("pencil", "إعادة التسمية", openRename));
  if (can.canArchive) rows.push(row(project.archivedAt ? "undo" : "archive", archiveLabel(project), toggleArchive));
  if (can.canDelete) {
    if (rows.length) rows.push(h("li", { className: "menu-separator", role: "separator" }));
    rows.push(row("trash", "حذف المشروع", confirmDelete, true));
  }
  el.replaceChildren(h("ul", { className: "menu-list", role: "list" }, ...rows));
  if (el.matches(":popover-open")) el.hidePopover();
  el.style.setProperty("--menu-top", "0px");
  el.style.setProperty("--menu-end", "0px");
  el.showPopover();

  const anchor = source.getBoundingClientRect();
  const fromButton = event.type === "click" || performance.now() - lastMenuKey < 500 || (event.clientX === 0 && event.clientY === 0);
  const rtl = document.documentElement.dir === "rtl";
  const x = fromButton ? (rtl ? anchor.right : anchor.left) : event.clientX;
  const y = fromButton ? anchor.bottom + 4 : event.clientY;
  const box = el.getBoundingClientRect();
  const gap = 8;
  // Toward the reading direction from the point (to its left in Arabic), and on screen.
  let left = rtl ? x - box.width : x;
  left = Math.min(Math.max(gap, left), window.innerWidth - box.width - gap);
  const top = Math.min(Math.max(gap, y), window.innerHeight - box.height - gap);
  el.style.setProperty("--menu-top", `${top}px`);
  el.style.setProperty("--menu-end", `${rtl ? left : window.innerWidth - left - box.width}px`);
  el.querySelector("button")?.focus();
}

/** A small modal sheet, made once per kind and refilled each time. */
function sheet(id, titleId, describedBy) {
  let dialog = document.getElementById(id);
  if (!dialog) {
    dialog = h("dialog", { className: "sheet sheet-small", id, "aria-labelledby": titleId, ...(describedBy ? { "aria-describedby": describedBy } : {}) });
    document.body.append(dialog);
  }
  return dialog;
}

// ——— «إعادة التسمية» ———

export function openRename(project, ctx) {
  const dialog = sheet("project-rename", "project-rename-title");
  const input = h("input", { className: "input body", id: "project-rename-name", type: "text", required: true, maxlength: "200", value: project.name, autocomplete: "off", enterkeyhint: "done" });
  const error = h("p", { className: "callout field-error", role: "alert" });
  const save = Button({ variant: "primary", type: "submit" }, "حفظ");
  const cancel = Button({ variant: "secondary" }, "إلغاء");
  const form = h(
    "form",
    { className: "sheet-form", novalidate: true },
    h("h2", { className: "title", id: "project-rename-title" }, "إعادة تسمية المشروع"),
    h("div", { className: "field" }, h("label", { className: "visually-hidden", for: "project-rename-name" }, "اسم المشروع"), input),
    error,
    h("div", { className: "sheet-actions" }, save, cancel),
  );
  cancel.addEventListener("click", () => dialog.close());
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const name = input.value.trim();
    if (!name) {
      error.textContent = "اكتب اسم المشروع.";
      input.focus();
      return;
    }
    if (name === project.name) return dialog.close();
    save.disabled = true;
    try {
      await api.updateProject(project.id, { name });
      dialog.close();
      ctx.announce(announcement.renamed(name));
      await ctx.refreshProjects();
    } catch (failure) {
      if (failure.status !== 401) error.textContent = projectErrorText(failure, "rename");
    } finally {
      save.disabled = false;
    }
  });
  dialog.replaceChildren(form);
  dialog.showModal();
  input.focus();
  input.select();
}

// ——— «أرشفة المشروع» و«استرجاع المشروع» ———

export async function toggleArchive(project, ctx) {
  const archiving = !project.archivedAt;
  try {
    await api.updateProject(project.id, { archivedAt: archiving ? Date.now() : null });
    ctx.announce(`${archiving ? announcement.archived(project.name) : announcement.restored(project.name)}${archiving ? ` ${ARCHIVE_NOTE}` : ""}`);
    // Leave its page first, so the redraw does not open a project that is gone from the lists.
    if (archiving) ctx.onRemoved?.(project);
    await ctx.refreshProjects();
  } catch (failure) {
    if (failure.status !== 401) ctx.showError?.(projectErrorText(failure, "archive"));
  }
}

// ——— «حذف المشروع» ———

export function confirmDelete(project, ctx) {
  const dialog = sheet("project-delete", "project-delete-title", "project-delete-text");
  const yes = Button({ variant: "secondary", className: "danger" }, "حذف المشروع");
  const no = Button({ variant: "quiet" }, "إلغاء");
  const error = h("p", { className: "callout field-error", role: "alert" });
  dialog.replaceChildren(
    h(
      "div",
      { className: "sheet-form" },
      h("h2", { className: "title", id: "project-delete-title" }, deleteQuestion(project.name)),
      h("p", { className: "callout", id: "project-delete-text" }, DELETE_NOTE),
      error,
      h("div", { className: "sheet-actions" }, yes, no),
    ),
  );
  no.addEventListener("click", () => dialog.close());
  yes.addEventListener("click", async () => {
    yes.disabled = true;
    try {
      await api.deleteProject(project.id);
      dialog.close();
      ctx.announce(announcement.deleted(project.name));
      ctx.onRemoved?.(project);
      await ctx.refreshProjects();
    } catch (failure) {
      if (failure.status !== 401) error.textContent = projectErrorText(failure, "delete");
      yes.disabled = false;
    }
  });
  dialog.showModal();
  // The safe answer has the focus: Enter does not delete.
  no.focus();
}
