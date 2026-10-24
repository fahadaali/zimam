// «تاريخ البداية»: a task's start date, which makes it span the days up to its due date (lib/spans.js).
//   - In «إضافة مهمة»: an optional field under the date, checked against it; `startDate` is sent
//     only when it is set, so a server that does not know the field yet keeps working.
//   - In the task details: «المدة» with «تغيير المدة…», which opens the start and due dates inline.
//   - «تغيير المدة…» as a dialog: the timeline's keyboard way to move and resize a bar.
// Plain DOM through h() and textContent; nothing here parses HTML.
import { Button, h, lightDismiss } from "./lib/components.js";
import { dualDate, isIsoDate, relativeDay, weekdayName } from "./lib/dates.js";
import { boardApi } from "./lib/feature-api.js";
import { START_ERRORS, checkStart, spanText, taskSpan } from "./lib/spans.js";

const dayText = (iso, { primary, today }) => {
  const word = relativeDay(iso, today);
  const full = dualDate(iso, { primary, today });
  return word ? `${word}، ${full}` : `${weekdayName(iso)}، ${full}`;
};

/**
 * The PATCH for a start and a due date typed in a form ("" for none). A start on the due day is
 * no start; `startDate` is left out for a task that never had one and still has none.
 */
export function durationPatch(task, start, due) {
  const patch = { dueDate: due || null };
  const startDate = start && due && start !== due ? start : null;
  if (startDate != null || task.startDate != null) patch.startDate = startDate;
  return patch;
}

// ——— «إضافة مهمة» ———

/**
 * Wires the add form's «تاريخ البداية» (index.html #add-start). `els`: { start, due, preview, error };
 * `context()` → { primary, today }. Returns { reset, check, fields } for main.js.
 */
export function addStartField(els, context) {
  const clearError = () => {
    els.error.textContent = "";
    els.start.removeAttribute("aria-invalid");
  };
  const update = () => {
    const value = els.start.value;
    els.preview.textContent = isIsoDate(value) ? dayText(value, context()) : "بلا تاريخ بداية";
  };
  els.start.addEventListener("input", () => {
    clearError();
    update();
  });
  // A due date changed by hand or by the assistant may make the start valid again.
  els.due.addEventListener("input", () => {
    if (els.start.getAttribute("aria-invalid") === "true" && !checkStart(els.start.value, els.due.value)) clearError();
  });
  return {
    reset() {
      els.start.value = "";
      clearError();
      update();
    },
    /** True when the start date may be sent; otherwise shows why and focuses the field. */
    check() {
      const code = isIsoDate(els.start.value) ? checkStart(els.start.value, els.due.value) : null;
      if (!code) return true;
      els.error.textContent = START_ERRORS[code];
      els.start.setAttribute("aria-invalid", "true");
      els.start.focus();
      return false;
    },
    /** `{ startDate }` when one is set (and not the due day itself), otherwise nothing at all. */
    fields() {
      const start = els.start.value;
      return isIsoDate(start) && isIsoDate(els.due.value) && start !== els.due.value ? { startDate: start } : {};
    },
  };
}

// ——— The start and due dates together ———

let formCount = 0;

/**
 * A form with «تاريخ البداية» and «الموعد», each with its dates in both calendars beneath.
 * `ctx`: { primary, today, errorText, announce, markLocalChange }. `onSaved(task)` after the server
 * accepted it; `onCancel()` for «إلغاء».
 */
export function durationForm(task, ctx, { onSaved, onCancel }) {
  const n = ++formCount;
  const field = (id, label, value, hint) => {
    const input = h("input", { className: "input body", id, type: "date", value: value ?? "", "aria-describedby": `${id}-preview ${id}-error` });
    const preview = h("p", { className: "caption muted", id: `${id}-preview`, "aria-live": "polite" });
    const error = h("p", { className: "caption field-error", id: `${id}-error` });
    const wrap = h("div", { className: "field" }, h("label", { className: "headline", for: id }, label, hint ? h("span", { className: "caption muted" }, ` ${hint}`) : null), input, preview, error);
    return { input, preview, error, wrap };
  };
  const span = taskSpan(task);
  const start = field(`span-start-${n}`, "تاريخ البداية", span && span.start !== span.end ? span.start : "", "(اختياري)");
  const due = field(`span-due-${n}`, "الموعد", task.dueDate ?? "");
  const formError = h("p", { className: "callout field-error", role: "alert" });
  const save = Button({ variant: "primary", type: "submit" }, "حفظ المدة");
  const cancel = Button({ variant: "quiet" }, "إلغاء");
  const form = h("form", { className: "duration-form", novalidate: true }, start.wrap, due.wrap, formError, h("div", { className: "sheet-actions" }, save, cancel));

  const preview = (f, empty) => (f.preview.textContent = isIsoDate(f.input.value) ? dayText(f.input.value, ctx) : empty);
  const clear = () => {
    for (const f of [start, due]) {
      f.error.textContent = "";
      f.input.removeAttribute("aria-invalid");
    }
    formError.textContent = "";
  };
  const update = () => {
    preview(start, "بلا تاريخ بداية");
    preview(due, "بلا موعد");
  };
  start.input.addEventListener("input", () => (clear(), update()));
  due.input.addEventListener("input", () => (clear(), update()));
  cancel.addEventListener("click", () => onCancel?.());
  form.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !form.closest("dialog")) {
      event.preventDefault();
      event.stopPropagation();
      onCancel?.();
    }
  });
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    clear();
    const s = isIsoDate(start.input.value) ? start.input.value : "";
    const d = isIsoDate(due.input.value) ? due.input.value : "";
    const code = checkStart(s, d);
    if (code) {
      start.error.textContent = START_ERRORS[code];
      start.input.setAttribute("aria-invalid", "true");
      start.input.focus();
      return;
    }
    const patch = durationPatch(task, s, d);
    save.disabled = true;
    ctx.markLocalChange?.();
    try {
      const saved = await boardApi.patchTask(task.id, patch);
      Object.assign(task, saved);
      ctx.announce?.(`صارت المدة: ${spanText(taskSpan(task), ctx)}.`);
      onSaved?.(task);
    } catch (error) {
      if (error.status !== 401) formError.textContent = ctx.errorText(error);
    } finally {
      save.disabled = false;
    }
  });
  update();
  return { form, focus: () => (start.input.value || !due.input.value ? start.input : due.input).focus() };
}

/** «تغيير المدة…» as a modal dialog (the timeline's keyboard alternative to dragging). */
export function openDurationDialog(task, ctx, onSaved) {
  let dialog = document.getElementById("duration-dialog");
  if (!dialog) {
    dialog = h("dialog", { className: "sheet", id: "duration-dialog", "aria-labelledby": "duration-title" });
    dialog.setAttribute("closedby", "any");
    lightDismiss(dialog);
    document.body.append(dialog);
  }
  const close = () => dialog.close();
  const { form, focus } = durationForm(task, ctx, {
    onSaved: (saved) => {
      close();
      onSaved?.(saved);
    },
    onCancel: close,
  });
  dialog.replaceChildren(
    h(
      "div",
      { className: "sheet-form" },
      h("h2", { className: "title", id: "duration-title" }, "تغيير المدة"),
      h("p", { className: "callout muted task-dialog-title" }, task.title),
      form,
    ),
  );
  dialog.showModal();
  focus();
}

/**
 * «المدة» in the task details: the span in words and, for editors, «تغيير المدة…» opening the
 * form in place. `ctx` as showTaskExtras gets it (with `role`, `canEditTask`, `render`, `onChanged`,
 * `isCurrent`). `update()` on the section redraws the words after the task's dates changed elsewhere;
 * an open form keeps what is typed in it.
 */
export function durationSection(task, ctx) {
  const titleId = "task-span-title";
  const text = h("p", { className: "body" }, spanText(taskSpan(task), ctx));
  const section = h("section", { className: "extra-section", "aria-labelledby": titleId }, h("h3", { className: "headline", id: titleId }, "المدة"), text);
  section.update = () => (text.textContent = spanText(taskSpan(task), ctx));
  if (!ctx.canEditTask?.(task)) return section;
  const open = Button({ variant: "secondary", "aria-expanded": "false" }, "تغيير المدة…");
  const slot = h("div");
  open.addEventListener("click", () => {
    const { form, focus } = durationForm(task, ctx, {
      onSaved: () => {
        if (!ctx.isCurrent?.()) return;
        section.update();
        close();
        // The editor's «الموعد» above follows the new dates, and so does the list.
        ctx.onChanged?.(task);
        ctx.render?.();
      },
      onCancel: close,
    });
    slot.replaceChildren(form);
    open.hidden = true;
    open.setAttribute("aria-expanded", "true");
    focus();
  });
  function close() {
    slot.replaceChildren();
    open.hidden = false;
    open.setAttribute("aria-expanded", "false");
    open.focus();
  }
  section.append(h("div", null, open), slot);
  return section;
}
