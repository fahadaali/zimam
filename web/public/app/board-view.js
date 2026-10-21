// A project as a kanban board, as in the Apple app (KanbanBoardView, Store+Board.swift): one column
// per section with «بلا قسم» first, so in Arabic the first column sits at the right edge. Tasks move
// by drag and drop between and within columns (HTML5 DnD), and from each card's «نقل» menu
// (up, down, «نقل إلى…») for the keyboard. Orders follow lib/order.js (ManualOrder). The list,
// board or timeline (timeline-view.js) choice is the project's `view`, so it follows the project
// to the app.
// Plain DOM through h() and textContent; nothing here parses HTML.
import { errorText } from "./lib/api.js";
import { Button, h, icons } from "./lib/components.js";
import { boardApi, nextUpdatedAt } from "./lib/feature-api.js";
import { after, boardColumns, byManualOrder, dropIndex, moveSection, placeTask, shownColumns } from "./lib/order.js";
import { arabicNumber } from "./lib/numbers.js";
import { canEdit } from "./lib/sharing.js";

// ——— List, board or timeline ———

const LAYOUTS = ["list", "kanban", "timeline"];

/** A viewer's own choice for this page's life: viewers cannot change the project's `view`. */
const localLayout = new Map();

// «مخطط» is saved as the project's view "timeline". A server that does not accept that value yet
// answers 400 (`invalid`); the choice is then kept for this browser tab (sessionStorage) instead.
const SESSION_KEY = "zimam.projectLayouts";

function sessionLayouts() {
  try {
    return JSON.parse(sessionStorage.getItem(SESSION_KEY) ?? "{}") ?? {};
  } catch {
    return {};
  }
}

function rememberLayout(projectId, value) {
  try {
    const all = sessionLayouts();
    if (value) all[projectId] = value;
    else delete all[projectId];
    sessionStorage.setItem(SESSION_KEY, JSON.stringify(all));
  } catch {
    /* kept for this page only */
  }
}

export function layoutOf(project) {
  const chosen = localLayout.get(project.id) ?? sessionLayouts()[project.id];
  if (LAYOUTS.includes(chosen)) return chosen;
  return LAYOUTS.includes(project.view) ? project.view : "list";
}

/** «قائمة» / «لوحة» / «مخطط»: saves the project's `view` (owner and editor), then redraws the view. */
export function layoutToggle(project, ctx) {
  const current = layoutOf(project);
  const make = (value, label) => {
    const button = h("button", { type: "button", className: "segment callout", "aria-pressed": String(current === value) }, label);
    button.addEventListener("click", async () => {
      if (layoutOf(project) === value) return;
      localLayout.set(project.id, value);
      rememberLayout(project.id, null);
      ctx.render();
      if (!canEdit(project.role)) return;
      try {
        const saved = await boardApi.setView(project.id, value);
        project.view = saved.view;
        localLayout.delete(project.id);
      } catch (error) {
        // An older server knows no "timeline" view: keep the choice in this tab, say nothing.
        if (value === "timeline" && error.status === 400) rememberLayout(project.id, value);
        else if (error.status !== 401 && error.status !== 403) ctx.showError(error);
      }
    });
    return button;
  };
  return h("div", { className: "segmented", role: "group", "aria-label": "طريقة العرض" }, make("list", "قائمة"), make("kanban", "لوحة"), make("timeline", "مخطط"));
}

// ——— The board ———

let dragged = null;

/**
 * The board. `project` has `role`; `sections` from GET /v1/projects/:id; `tasks` the project's
 * tasks. `ctx`: { taskItem(task, options), announce, showError, render, markLocalChange }.
 */
export function boardView({ project, sections, tasks }, ctx) {
  const editable = canEdit(project.role);
  const board = h("div", { className: "board", role: "region", "aria-label": `لوحة ${project.name}` });
  let columns = [];

  const draw = (focus) => {
    columns = boardColumns(sections, tasks);
    const shown = shownColumns(columns);
    board.replaceChildren(...shown.map((column) => columnView(column)), ...(editable ? [addSectionControl()] : []));
    if (focus) board.querySelector(focus)?.focus();
  };

  // ——— Saving ———

  async function saveTasks(changes, message) {
    for (const change of changes) Object.assign(tasks.find((t) => t.id === change.id) ?? {}, change);
    ctx.markLocalChange();
    ctx.announce(message);
    try {
      await Promise.all(changes.map((c) => boardApi.patchTask(c.id, { sortOrder: c.sortOrder, sectionId: c.sectionId })));
    } catch (error) {
      if (error.status === 401) return;
      ctx.showError(error);
      ctx.render();
    }
  }

  async function saveSections(mutations, message) {
    ctx.markLocalChange();
    try {
      await boardApi.sections(mutations);
      if (message) ctx.announce(message);
      return true;
    } catch (error) {
      if (error.status !== 401) ctx.showError(error);
      ctx.render();
      return false;
    }
  }

  /** Puts a task in a column at `index` (counted without it), as Store.place does. */
  function place(task, column, index) {
    const changes = placeTask(task, column.section?.id ?? null, index, column.tasks);
    if (changes.length === 0) return;
    const moved = changes.find((c) => c.id === task.id);
    saveTasks(changes, moved && (task.sectionId ?? null) !== (column.section?.id ?? null) ? `نُقلت إلى «${column.name}».` : "تغيّر ترتيب المهمة.");
    // Focus follows the card to its new place.
    draw(`[data-task-id="${CSS.escape(task.id)}"] .card-move`);
  }

  // ——— Columns ———

  function columnView(column) {
    const titleId = `col-${column.id}`;
    const title = h("h3", { className: "zm-column-title", id: titleId }, column.name);
    const head = h("header", { className: "zm-column-head" }, title, h("span", { className: "zm-count" }, arabicNumber(column.tasks.length)));
    const body = h("ul", { className: "zm-column-body", role: "list", "aria-labelledby": titleId });
    column.tasks.forEach((task, i) => body.append(card(task, column, i)));
    const el = h("section", { className: "zm-column board-column", "aria-labelledby": titleId, dataset: { column: column.id } }, head);
    if (editable && column.section) head.append(sectionMenu(column, head, title));
    el.append(body);
    if (editable) el.append(addTaskControl(column));
    if (editable) dropTarget(el, body, column);
    return el;
  }

  function card(task, column, index) {
    const li = ctx.taskItem(task, { showDate: true, showProject: false, leaveWhenDone: true });
    li.classList.add("board-card");
    li.dataset.taskId = task.id;
    li.firstElementChild?.classList.add("zm-task-compact");
    if (!editable) return li;
    li.draggable = true;
    li.addEventListener("dragstart", (event) => {
      dragged = { id: task.id, height: li.getBoundingClientRect().height };
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", task.title);
      event.dataTransfer.setData("application/x-zimam-task", task.id);
      li.classList.add("is-dragged");
      li.firstElementChild?.classList.add("zm-task-lifted");
      document.body.classList.add("is-dragging");
    });
    li.addEventListener("dragend", () => {
      dragged = null;
      li.classList.remove("is-dragged");
      li.firstElementChild?.classList.remove("zm-task-lifted");
      document.body.classList.remove("is-dragging");
      board.querySelectorAll(".drop-placeholder").forEach((p) => p.remove());
      board.querySelectorAll(".is-target").forEach((c) => c.classList.remove("is-target"));
    });
    li.append(moveMenu(task, column, index));
    return li;
  }

  function dropTarget(el, body, column) {
    const indexAt = (y) => {
      const cards = [...body.querySelectorAll(".board-card")].filter((c) => c.dataset.taskId !== dragged?.id);
      return { cards, index: dropIndex(y, cards.map((c) => { const r = c.getBoundingClientRect(); return r.top + r.height / 2; })) };
    };
    el.addEventListener("dragover", (event) => {
      if (!dragged) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      board.querySelectorAll(".is-target").forEach((c) => c !== el && c.classList.remove("is-target"));
      el.classList.add("is-target");
      // A gap the card's height opens where it would land.
      let gap = board.querySelector(".drop-placeholder");
      if (!gap) {
        gap = h("li", { className: "drop-placeholder", "aria-hidden": "true" });
        gap.style.setProperty("block-size", `${dragged.height}px`);
      }
      const { cards, index } = indexAt(event.clientY);
      const before = cards[index] ?? null;
      if (gap.parentElement !== body || gap.nextElementSibling !== before) body.insertBefore(gap, before);
    });
    el.addEventListener("dragleave", (event) => {
      if (!el.contains(event.relatedTarget)) el.classList.remove("is-target");
    });
    el.addEventListener("drop", (event) => {
      if (!dragged) return;
      event.preventDefault();
      const task = tasks.find((t) => t.id === dragged.id);
      const { index } = indexAt(event.clientY);
      dragged = null;
      document.body.classList.remove("is-dragging");
      if (task) place(task, column, index);
    });
  }

  // ——— The card's «نقل» menu: the keyboard's way to move ———

  function moveMenu(task, column, index) {
    const menuId = `move-${task.id}`;
    const toggle = h(
      "button",
      { type: "button", className: "card-move caption", "aria-expanded": "false", "aria-controls": menuId, "aria-haspopup": "true", "aria-label": `نقل: ${task.title}` },
      "نقل",
    );
    const items = [];
    const item = (label, action, disabled = false) => {
      const b = h("button", { type: "button", role: "menuitem", className: "menu-item callout", disabled }, label);
      b.addEventListener("click", () => {
        close();
        action();
      });
      items.push(b);
      return b;
    };
    const menu = h("div", { className: "card-menu", id: menuId, role: "menu", "aria-label": `نقل «${task.title}»`, hidden: true });
    menu.append(
      item("إلى الأعلى", () => place(task, column, index - 1), index === 0),
      item("إلى الأسفل", () => place(task, column, index + 1), index === column.tasks.length - 1),
      ...columns.filter((c) => c.id !== column.id).map((c) => item(`نقل إلى «${c.name}»`, () => place(task, c, c.tasks.length))),
    );
    const enabled = () => items.filter((b) => !b.disabled);
    const open = () => {
      menu.hidden = false;
      toggle.setAttribute("aria-expanded", "true");
      enabled()[0]?.focus();
    };
    const close = (focusToggle = false) => {
      menu.hidden = true;
      toggle.setAttribute("aria-expanded", "false");
      if (focusToggle) toggle.focus();
    };
    toggle.addEventListener("click", () => (menu.hidden ? open() : close()));
    menu.addEventListener("keydown", (event) => {
      const list = enabled();
      const at = list.indexOf(document.activeElement);
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        close(true);
      } else if (event.key === "ArrowDown") {
        event.preventDefault();
        list[(at + 1) % list.length]?.focus();
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        list[(at - 1 + list.length) % list.length]?.focus();
      } else if (event.key === "Home") {
        event.preventDefault();
        list[0]?.focus();
      } else if (event.key === "End") {
        event.preventDefault();
        list[list.length - 1]?.focus();
      }
    });
    const wrap = h("div", { className: "card-tools" }, toggle, menu);
    wrap.addEventListener("focusout", (event) => {
      if (!menu.hidden && !wrap.contains(event.relatedTarget)) close();
    });
    return wrap;
  }

  // ——— Adding tasks ———

  function addTaskControl(column) {
    const open = h("button", { type: "button", className: "zm-column-add" }, "إضافة مهمة");
    const input = h("input", { className: "input callout", type: "text", maxlength: "500", "aria-label": `عنوان المهمة في «${column.name}»`, enterkeyhint: "done" });
    const error = h("p", { className: "caption field-error", role: "alert" });
    const form = h("form", { className: "column-form", hidden: true, novalidate: true }, input, h("div", { className: "sheet-actions" }, Button({ variant: "secondary", type: "submit" }, "إضافة"), cancelButton()), error);
    function cancelButton() {
      const b = Button({ variant: "quiet" }, "إلغاء");
      b.addEventListener("click", () => {
        form.hidden = true;
        open.hidden = false;
        open.focus();
      });
      return b;
    }
    open.addEventListener("click", () => {
      open.hidden = true;
      form.hidden = false;
      input.focus();
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        form.querySelector(".zm-btn-quiet").click();
      }
    });
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const title = input.value.trim();
      if (!title) {
        error.textContent = "اكتب عنوان المهمة.";
        input.focus();
        return;
      }
      error.textContent = "";
      input.disabled = true;
      try {
        ctx.markLocalChange();
        const created = await boardApi.createTask({
          title,
          projectId: project.id,
          sectionId: column.section?.id ?? null,
          sortOrder: after(column.tasks.map((t) => t.sortOrder ?? 0)),
        });
        tasks.push(created);
        ctx.announce(`أُضيفت المهمة إلى «${column.name}».`);
        ctx.refreshProjects?.();
        draw();
        // Keep adding to the same column.
        const again = board.querySelector(`[data-column="${CSS.escape(column.id)}"] .zm-column-add`);
        again?.click();
      } catch (failure) {
        input.disabled = false;
        if (failure.status !== 401) error.textContent = errorText(failure);
      }
    });
    return h("div", { className: "column-add" }, open, form);
  }

  // ——— Sections ———

  function addSectionControl() {
    const open = h("button", { type: "button", className: "board-add-section callout" }, icons.plus(), h("span", null, "إضافة قسم"));
    const input = h("input", { className: "input callout", type: "text", maxlength: "100", "aria-label": "اسم القسم" });
    const cancel = Button({ variant: "quiet" }, "إلغاء");
    const form = h("form", { className: "column-form", hidden: true, novalidate: true }, input, h("div", { className: "sheet-actions" }, Button({ variant: "secondary", type: "submit" }, "إضافة"), cancel));
    cancel.addEventListener("click", () => {
      form.hidden = true;
      open.hidden = false;
      open.focus();
    });
    open.addEventListener("click", () => {
      open.hidden = true;
      form.hidden = false;
      input.focus();
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        cancel.click();
      }
    });
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const name = input.value.trim();
      if (!name) return input.focus();
      const section = { id: crypto.randomUUID(), projectId: project.id, name, sortOrder: after(sections.map((s) => s.sortOrder ?? 0)), updatedAt: Date.now(), createdAt: Date.now() };
      input.disabled = true;
      if (await saveSections([{ op: "upsert", entity: "section", data: section }], `أُضيف القسم «${name}».`)) {
        sections.push(section);
        draw(".board-add-section");
      }
    });
    return h("div", { className: "board-column-add" }, open, form);
  }

  function sectionMenu(column, head, title) {
    const section = column.section;
    const ordered = sections.slice().sort(byManualOrder);
    const at = ordered.findIndex((s) => s.id === section.id);
    const menuId = `section-${section.id}`;
    const toggle = h("button", { type: "button", className: "card-move caption", "aria-expanded": "false", "aria-controls": menuId, "aria-label": `خيارات القسم «${section.name}»` }, "خيارات");
    const menu = h("div", { className: "card-menu", id: menuId, hidden: true });
    const close = () => {
      menu.hidden = true;
      toggle.setAttribute("aria-expanded", "false");
    };
    const entry = (label, action, disabled = false) => {
      const b = h("button", { type: "button", className: "menu-item callout", disabled }, label);
      b.addEventListener("click", () => {
        close();
        action();
      });
      return b;
    };
    const shift = (offset, message) => async () => {
      const changes = moveSection(sections, section.id, offset);
      if (!changes.length) return;
      const mutations = changes.map((c) => {
        const s = sections.find((x) => x.id === c.id);
        s.sortOrder = c.sortOrder;
        s.updatedAt = nextUpdatedAt(s.updatedAt);
        return { op: "upsert", entity: "section", data: { id: s.id, projectId: project.id, name: s.name, sortOrder: s.sortOrder, updatedAt: s.updatedAt } };
      });
      draw(`[data-column="${CSS.escape(section.id)}"] .zm-column-head .card-move`);
      await saveSections(mutations, message);
    };
    menu.append(
      entry("تسمية القسم", rename),
      entry("تقديم القسم", shift(-1, "قُدّم القسم."), at <= 0),
      entry("تأخير القسم", shift(1, "أُخّر القسم."), at === ordered.length - 1),
      entry("حذف القسم", confirmDelete),
    );
    toggle.addEventListener("click", () => {
      menu.hidden = !menu.hidden;
      toggle.setAttribute("aria-expanded", String(!menu.hidden));
      if (!menu.hidden) menu.querySelector("button:not(:disabled)")?.focus();
    });
    menu.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        close();
        toggle.focus();
      }
    });
    const wrap = h("div", { className: "card-tools section-tools" }, toggle, menu);
    wrap.addEventListener("focusout", (event) => {
      if (!menu.hidden && !wrap.contains(event.relatedTarget)) close();
    });

    function rename() {
      const input = h("input", { className: "input callout", type: "text", maxlength: "100", value: section.name, "aria-label": "اسم القسم" });
      const save = Button({ variant: "secondary", type: "submit" }, "حفظ");
      const cancel = Button({ variant: "quiet" }, "إلغاء");
      const form = h("form", { className: "column-form", novalidate: true }, input, h("div", { className: "sheet-actions" }, save, cancel));
      cancel.addEventListener("click", () => draw(`[data-column="${CSS.escape(section.id)}"] .zm-column-head .card-move`));
      input.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          cancel.click();
        }
      });
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        const name = input.value.trim();
        if (!name || name === section.name) return cancel.click();
        section.name = name;
        section.updatedAt = nextUpdatedAt(section.updatedAt);
        draw(`[data-column="${CSS.escape(section.id)}"] .zm-column-head .card-move`);
        await saveSections(
          [{ op: "upsert", entity: "section", data: { id: section.id, projectId: project.id, name, sortOrder: section.sortOrder ?? 0, updatedAt: section.updatedAt } }],
          `صار اسم القسم «${name}».`,
        );
      });
      head.replaceChildren(form);
      input.focus();
      input.select();
    }

    function confirmDelete() {
      const yes = Button({ variant: "secondary", className: "danger" }, "حذف القسم");
      const no = Button({ variant: "quiet" }, "إلغاء");
      no.addEventListener("click", () => draw(`[data-column="${CSS.escape(section.id)}"] .zm-column-head .card-move`));
      yes.addEventListener("click", async () => {
        yes.disabled = true;
        const updatedAt = nextUpdatedAt(section.updatedAt);
        if (await saveSections([{ op: "delete", entity: "section", id: section.id, updatedAt }], `حُذف القسم «${section.name}».`)) {
          // Its tasks stay in the project with no section, as the server does.
          for (const t of tasks) if (t.sectionId === section.id) t.sectionId = null;
          sections.splice(sections.indexOf(section), 1);
          draw(".board-add-section");
        }
      });
      head.replaceChildren(h("div", { className: "column-form" }, h("p", { className: "callout" }, `حذف «${section.name}»؟ تبقى مهامه في المشروع بلا قسم.`), h("div", { className: "sheet-actions" }, yes, no)));
      no.focus();
    }

    return wrap;
  }

  draw();
  return board;
}
