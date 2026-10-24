// The open task (index.html #inspector), as TaskDetailView sits in MainView.swift: an inspector
// beside the list on wide screens, its own page on phones. Its toolbar has «رجوع» or «إغلاق» and
// the primary «إنجاز» / «إلغاء الإنجاز»; below are the task's details, the extras (task-extras.js),
// the attachments (attachments-view.js), and «حذف المهمة» with its confirmation.
import { showAttachments } from "./attachments-view.js";
import { PrayerChip, h, isTyping } from "./lib/components.js";
import { icon } from "./lib/icons.js";
import { dualDate, relativeDay, timeLabel, weekdayName } from "./lib/dates.js";
import { prayerPhrase } from "./lib/prayer.js";
import { PRIORITY_WORDS, isOpen } from "./lib/tasks.js";
import { remindersSection, taskEditor } from "./task-editor.js";
import { reloadTaskExtras, showTaskExtras, updateTaskExtras } from "./task-extras.js";

const $ = (id) => document.getElementById(id);

/**
 * `ctx` (from main.js): { primary(), today(), projectName(id), roleFor(task), canEdit(task),
 * writableProjects(), save(task, fields) → Promise<task>, featureContext(), toggle(task),
 * remove(task), close({ restoreFocus }), announce, errorText, markLocalChange, api }.
 */
export function createTaskPane(ctx) {
  const els = {
    shell: $("shell"),
    pane: $("inspector"),
    title: $("task-title"),
    missing: $("task-missing"),
    details: $("task-details"),
    editor: $("task-editor"),
    extras: $("task-extras"),
    attachments: $("task-attachments"),
    error: $("task-error"),
    actions: $("task-actions"),
    confirm: $("task-confirm"),
    toggle: $("task-toggle"),
    toggleLabel: $("task-toggle-label"),
  };
  let current = null;
  /** The «التذكيرات» section of the task shown, read once and kept across redraws. */
  let reminders = null;
  /** The attachments of the task shown (attachments-view.js), to read them again. */
  let attachments = null;
  /**
   * The editor's error line, kept across its redraws: an edit redraws the editor at once (main.js
   * saveTask), so a save that fails afterwards still has somewhere to say why.
   */
  const editorError = h("p", { className: "callout field-error", role: "alert" });

  /** What the extras need, for the task as it is now (its role follows a move to another project). */
  const extrasCtx = (task) => ({ ...ctx.featureContext(), role: ctx.roleFor(task), isTaskShown: (id) => current?.id === id });

  function detail(term, ...value) {
    return [h("dt", { className: "caption muted" }, term), h("dd", { className: "body" }, ...value)];
  }

  /** The editor for those who can change the task, the details as text for the rest. */
  function fill(task) {
    els.title.textContent = task.title;
    els.missing.hidden = true;
    els.error.textContent = "";
    els.actions.hidden = !ctx.canEdit(task);
    els.confirm.hidden = true;
    setToggle(task);
    if (!ctx.canEdit(task)) {
      els.title.classList.remove("sr-only");
      fillDetails(task);
      els.editor.replaceChildren(reminders.node);
      return;
    }
    // The title is the editor's first field; the heading stays for screen readers to land on.
    els.title.classList.add("sr-only");
    els.details.replaceChildren();
    // A redraw while a field has focus gives it back, with what was being typed in it.
    const active = document.activeElement;
    const key = els.editor.contains(active) ? active.dataset.key : null;
    const typing = key && (active.tagName === "TEXTAREA" || (active.tagName === "INPUT" && /^(text|search)$/.test(active.type)));
    const draft = typing ? { value: active.value, start: active.selectionStart, end: active.selectionEnd } : null;
    const editorCtx = {
      primary: ctx.primary(),
      today: ctx.today(),
      projects: ctx.writableProjects(),
      projectName: ctx.projectName,
      save: (fields) => ctx.save(task, fields),
      isCurrent: () => current?.id === task.id,
      announce: ctx.announce,
      errorText: ctx.errorText,
      error: editorError,
      ensureAtTimeReminder: () => reminders.ensureAtTime(),
    };
    els.editor.replaceChildren(taskEditor(task, editorCtx, reminders.node));
    reminders.redraw();
    if (!key) return;
    const again = els.editor.querySelector(`[data-key="${CSS.escape(key)}"]`);
    if (!again) return;
    if (draft) {
      again.value = draft.value;
      again.setSelectionRange?.(draft.start, draft.end);
    }
    again.focus({ preventScroll: true });
  }

  /** The read-only details; fill() has already set the toolbar and «حذف المهمة» for the role. */
  function fillDetails(task) {
    const today = ctx.today();
    const primary = ctx.primary();
    const rows = [];
    if (task.dueDate) {
      const word = relativeDay(task.dueDate, today);
      const full = dualDate(task.dueDate, { primary, today });
      rows.push(...detail("الموعد", word ? `${word}، ${full}` : `${weekdayName(task.dueDate)}، ${full}`));
    }
    const prayer = prayerPhrase(task.duePrayer, task.duePrayerOffset);
    if (prayer) rows.push(...detail("الوقت", PrayerChip(prayer)));
    else if (task.dueTime) rows.push(...detail("الوقت", timeLabel(task.dueTime)));
    rows.push(...detail("المشروع", task.projectId ? (ctx.projectName(task.projectId) ?? "مشروع مشترك") : "صندوق المهام"));
    rows.push(...detail("الأولوية", PRIORITY_WORDS[task.priority] ?? PRIORITY_WORDS[0]));
    if (task.tags?.length) rows.push(...detail("الوسوم", task.tags.join("، ")));
    if (task.notes) rows.push(...detail("ملاحظات", h("span", { className: "notes" }, task.notes)));
    els.details.replaceChildren(...rows);
  }

  function setToggle(task) {
    const done = !isOpen(task);
    els.toggleLabel.textContent = done ? "إلغاء الإنجاز" : "إنجاز";
    els.toggle.firstElementChild.replaceChildren(icon(done ? "undo" : "check"));
    els.toggle.hidden = !ctx.canEdit(task);
  }

  function open() {
    els.pane.hidden = false;
    els.shell.dataset.task = "";
  }

  /** Shows `task`; `focus` moves the keyboard to its title (a person opened it, not a reload). */
  function show(task, { focus = true } = {}) {
    current = task;
    editorError.textContent = "";
    reminders = remindersSection(task.id, () => current ?? task, {
      primary: ctx.primary(),
      isCurrent: () => current?.id === task.id,
      announce: ctx.announce,
      errorText: ctx.errorText,
      markLocalChange: ctx.markLocalChange,
    });
    fill(task);
    els.extras.hidden = false;
    els.attachments.hidden = false;
    attachments = showAttachments(els.attachments, task, { announce: ctx.announce });
    open();
    showTaskExtras(task, extrasCtx(task));
    els.pane.scrollTop = 0;
    if (focus) els.title.focus({ preventScroll: true });
  }

  /** «لم تعد هذه المهمة موجودة.»: the task was deleted elsewhere while it was open. */
  function showMissing() {
    current = null;
    els.title.textContent = "";
    els.missing.hidden = false;
    els.details.replaceChildren();
    els.editor.replaceChildren();
    els.extras.replaceChildren();
    els.attachments.replaceChildren();
    els.actions.hidden = true;
    els.confirm.hidden = true;
    els.toggle.hidden = true;
    open();
  }

  function hide() {
    current = null;
    els.pane.hidden = true;
    delete els.shell.dataset.task;
    els.extras.replaceChildren();
    els.editor.replaceChildren();
  }

  /**
   * The same task, newer: redraws the details and the toolbar, and the extras that follow its
   * fields («المدة», the assignee); the attachments and the lists in the extras stay as they are.
   */
  function refresh(task) {
    if (current?.id !== task.id) return;
    Object.assign(current, task);
    fill(current);
    updateTaskExtras(current, extrasCtx(current));
  }

  /**
   * Reads the open task's subtasks, comments and attachments again, after a change elsewhere. Each
   * list is drawn anew, so one that holds the focus (a subtask's circle, «حذف التعليق», a file) is
   * left as it is and read on the next change: the keyboard keeps its place.
   */
  function reloadLists() {
    if (!current) return;
    reloadTaskExtras(current.id);
    attachments?.reload();
  }

  els.toggle.addEventListener("click", () => current && ctx.toggle(current).then(() => current && setToggle(current)));
  $("task-back").addEventListener("click", () => ctx.close({ restoreFocus: true }));
  $("task-close").addEventListener("click", () => ctx.close({ restoreFocus: true }));

  // Esc closes the inspector on wide screens, unless a dialog opened from it is up.
  els.pane.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || document.querySelector("dialog[open]")) return;
    if (els.shell.dataset.layout !== "regular") return;
    event.preventDefault();
    ctx.close({ restoreFocus: true });
  });

  // ⌘↩ / Ctrl+↩: «إنجاز المهمة المحددة», as in the Mac menu. Not while typing in a field: there
  // the keys belong to the field (in the comment box they send the comment, share-view.js).
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey) || !current) return;
    if (document.querySelector("dialog[open]") || event.isComposing || isTyping(event.target)) return;
    event.preventDefault();
    ctx.toggle(current).then(() => current && setToggle(current));
  });

  $("task-delete").addEventListener("click", () => {
    els.actions.hidden = true;
    els.confirm.hidden = false;
    $("task-delete-cancel").focus();
  });
  $("task-delete-cancel").addEventListener("click", () => {
    els.confirm.hidden = true;
    els.actions.hidden = false;
    $("task-delete").focus();
  });
  $("task-delete-confirm").addEventListener("click", async (event) => {
    const button = event.currentTarget;
    const task = current;
    if (!task) return;
    button.disabled = true;
    try {
      await ctx.api.deleteTask(task.id);
      ctx.announce("حُذفت المهمة.");
      ctx.remove(task);
    } catch (error) {
      if (error.status !== 401) els.error.textContent = ctx.errorText(error);
    } finally {
      button.disabled = false;
    }
  });

  return {
    show,
    showMissing,
    hide,
    refresh,
    reloadLists,
    setToggle: (task) => current?.id === task.id && setToggle(current),
    currentId: () => current?.id ?? null,
    /** The task object the pane shows, if it is `id`. */
    currentTask: (id) => (current?.id === id ? current : null),
    isShown: (id) => !els.pane.hidden && current?.id === id,
    /** Whether a reload now would get in the way of typing in the pane. */
    isBusy: () => {
      const active = document.activeElement;
      return !els.pane.hidden && !!active && els.pane.contains(active) && active.matches("input, select, textarea");
    },
  };
}
