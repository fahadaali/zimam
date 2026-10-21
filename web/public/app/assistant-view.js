// The assistant on the web, as in the Apple app (AssistantViews.swift): «اقتراح بالمساعد» in the
// add-task form, «تقسيم إلى خطوات» in a task's details, and «ملخص اليوم» on Today. Nothing is saved
// before the person accepts: the suggestion card (design/components/AISuggestion) offers
// «إضافة», «تعديل» (fills the form) and «تجاهل».
// Plain DOM through h() and textContent; nothing here parses HTML.
import { Button, h } from "./lib/components.js";
import { icon } from "./lib/icons.js";
import { assistantErrorText, breakdownText, isoWithOffset, suggestionLines, suggestionToTask } from "./lib/assistant.js";
import { assistantApi, boardApi } from "./lib/feature-api.js";
import { after, byManualOrder } from "./lib/order.js";
import { canEdit } from "./lib/sharing.js";
import { arabicNumber } from "./lib/numbers.js";
import { isOpen } from "./lib/tasks.js";

const online = () => (typeof navigator === "undefined" ? true : navigator.onLine !== false);
const problem = (error, ctx) => assistantErrorText(error, { primary: ctx.primary, today: ctx.today, online: online() });

/** design/components/AISuggestion in plain DOM: label, text (nodes), and the actions given. */
export function AISuggestion({ label = "اقتراح المساعد", busy = false }, text, actions = []) {
  return h(
    "div",
    { className: "zm-ai", role: "group", "aria-label": label, "aria-busy": busy ? "true" : null },
    h("div", { className: "zm-ai-label" }, label),
    h("div", { className: "zm-ai-text" }, text),
    actions.length ? h("div", { className: "zm-ai-actions" }, actions) : null,
  );
}

function lines(list) {
  return h(
    "dl",
    { className: "ai-lines" },
    list.map(({ term, value }) => [h("dt", { className: "caption muted" }, term), h("dd", { className: "callout" }, value)]),
  );
}

// ——— «اقتراح بالمساعد» in the add-task form ———

const add = {
  ready: false,
  /** What the form cannot hold (notes, tags, a clock time) after «تعديل», added on submit. */
  extras: null,
  box: null,
  button: null,
  hint: null,
  run: 0,
};

/**
 * Puts «اقتراح بالمساعد» under the title field of the add dialog. `getCtx()` gives the current
 * { primary, today, projectName, announce, render, refreshProjects }.
 */
export function setupAddAssistant(getCtx) {
  if (add.ready) return;
  const title = document.getElementById("add-title-input");
  const field = title?.closest(".field");
  if (!field) return;
  add.ready = true;
  add.button = Button({ variant: "secondary", className: "assist-button", "aria-describedby": "assist-hint" }, "اقتراح بالمساعد");
  add.hint = h("p", { className: "caption muted", id: "assist-hint" }, "اكتب المهمة بجملة، مثل «ذكرني أراجع العقد بعد المغرب يوم الخميس»، ثم اطلب الاقتراح.");
  add.box = h("div", { className: "assist-box", "aria-live": "polite" });
  field.after(h("div", { className: "field assist" }, h("div", { className: "assist-row" }, add.button), add.hint, add.box));
  add.button.addEventListener("click", () => suggest(getCtx()));
}

/** Clears the card and anything kept from it, when the dialog opens again. */
export function resetAddAssistant() {
  add.run++;
  add.extras = null;
  add.box?.replaceChildren();
  if (add.button) add.button.disabled = false;
}

/** On submit: notes, tags and a clock time from an edited suggestion, while they still fit. */
export function withAssistantExtras(body) {
  const extras = add.extras;
  if (!extras) return body;
  const out = { ...body };
  if (extras.notes) out.notes = extras.notes;
  if (extras.tags?.length) out.tags = extras.tags;
  if (extras.dueTime && out.dueDate && !out.duePrayer) out.dueTime = extras.dueTime;
  return out;
}

async function suggest(ctx) {
  const titleInput = document.getElementById("add-title-input");
  const titleError = document.getElementById("add-title-error");
  const text = titleInput.value.trim();
  if (!text) {
    titleError.textContent = "اكتب جملة يقرؤها المساعد.";
    titleInput.setAttribute("aria-invalid", "true");
    titleInput.focus();
    return;
  }
  const run = ++add.run;
  add.extras = null;
  add.button.disabled = true;
  add.box.replaceChildren(h("p", { className: "callout muted", role: "status" }, "يقرأ المساعد المهمة…"));
  try {
    const suggestion = await assistantApi.parse(text, isoWithOffset());
    if (run !== add.run) return;
    showSuggestion(suggestionToTask(suggestion), ctx);
  } catch (error) {
    if (run !== add.run || error.status === 401) return;
    add.box.replaceChildren(h("p", { className: "callout assist-error", role: "alert" }, problem(error, ctx)));
  } finally {
    if (run === add.run) add.button.disabled = false;
  }
}

function showSuggestion(task, ctx) {
  const error = h("p", { className: "callout field-error", role: "alert" });
  const accept = Button({ variant: "primary" }, "إضافة");
  const edit = Button({ variant: "secondary" }, "تعديل");
  const dismiss = Button({ variant: "quiet" }, "تجاهل");
  accept.addEventListener("click", async () => {
    error.textContent = "";
    accept.disabled = true;
    try {
      ctx.markLocalChange?.();
      await boardApi.createTask(task);
      document.getElementById("add-dialog").close();
      ctx.announce("أُضيفت المهمة.");
      await ctx.refreshProjects();
      ctx.render();
    } catch (failure) {
      if (failure.status !== 401) error.textContent = ctx.errorText(failure);
      accept.disabled = false;
    }
  });
  edit.addEventListener("click", () => {
    fillForm(task);
    add.box.replaceChildren();
    document.getElementById("add-title-input").focus();
    ctx.announce("نُقل الاقتراح إلى النموذج. عدّله ثم أضف المهمة.");
  });
  dismiss.addEventListener("click", () => {
    add.box.replaceChildren();
    add.button.focus();
  });
  const card = AISuggestion({}, [h("p", null, "قرأت المهمة هكذا:"), lines(suggestionLines(task, ctx))], [accept, edit, dismiss]);
  add.box.replaceChildren(card, error);
  accept.focus();
}

/** «تعديل»: the suggestion into the form's fields, with their previews updated as if typed. */
function fillForm(task) {
  const form = document.getElementById("add-form");
  const set = (id, value, event) => {
    const el = document.getElementById(id);
    el.value = value;
    el.dispatchEvent(new Event(event, { bubbles: true }));
  };
  set("add-title-input", task.title, "input");
  set("add-date", task.dueDate ?? "", "input");
  set("add-prayer", task.duePrayer ?? "", "change");
  const offset = task.duePrayerOffset ?? 0;
  const relation = form.querySelector(`input[name="relation"][value="${offset < 0 ? "before" : "after"}"]`);
  if (relation) {
    relation.checked = true;
    relation.dispatchEvent(new Event("change", { bubbles: true }));
  }
  set("add-minutes", offset ? arabicNumber(Math.abs(offset)) : "", "input");
  const priority = form.querySelector(`input[name="priority"][value="${task.priority}"]`);
  if (priority) priority.checked = true;
  const project = document.getElementById("add-project");
  if (task.projectId && [...project.options].some((o) => o.value === task.projectId)) project.value = task.projectId;
  add.extras = { notes: task.notes, tags: task.tags, dueTime: task.dueTime };
}

// ——— «ملخص اليوم» on Today ———

/** One summary per day for this page's life, so a live reload keeps it. */
const summaries = new Map();

/** The summary block for Today: a button, then the card once asked. */
export function todaySummary(ctx) {
  const box = h("section", { className: "summary-box", "aria-label": "ملخص اليوم" });
  const draw = () => {
    const kept = summaries.get(ctx.today);
    if (kept?.text && !kept.hidden) {
      const hide = Button({ variant: "quiet" }, "إخفاء");
      hide.addEventListener("click", () => {
        kept.hidden = true;
        draw();
        box.querySelector("button")?.focus();
      });
      box.replaceChildren(AISuggestion({ label: "ملخص اليوم" }, kept.text, [hide]));
      return;
    }
    // DaySummaryRow: a quiet button, so «إضافة مهمة» stays the screen's one primary action.
    const ask = Button({ variant: "quiet", className: "summary-ask" }, icon("summary", { size: "sm" }), "ملخص اليوم");
    ask.addEventListener("click", () => load(ask));
    // replaceChildren() writes a null as the text "null", so only real nodes go in.
    box.replaceChildren(...[ask, kept?.error ? h("p", { className: "callout assist-error", role: "alert" }, kept.error) : null].filter(Boolean));
  };
  const load = async (ask) => {
    const kept = summaries.get(ctx.today);
    if (kept?.text) {
      kept.hidden = false;
      draw();
      return;
    }
    ask.disabled = true;
    box.append(h("p", { className: "callout muted", role: "status" }, "يجهّز المساعد ملخص اليوم…"));
    try {
      const { text } = await assistantApi.summary(ctx.today);
      summaries.set(ctx.today, { text, hidden: false });
      ctx.announce("جهز ملخص اليوم.");
    } catch (error) {
      if (error.status === 401) return;
      summaries.set(ctx.today, { error: problem(error, ctx) });
    }
    if (box.isConnected) {
      draw();
      box.querySelector(".zm-ai .zm-btn, button")?.focus();
    }
  };
  draw();
  return box;
}

// ——— «تقسيم إلى خطوات» in a task's details ———

/**
 * The task's subtasks and the breakdown. `ctx`: { primary, today, role, announce, errorText,
 * isCurrent() } where isCurrent() is false once the dialog shows another task.
 */
export function breakdownSection(task, ctx) {
  const list = h("ul", { className: "subtask-list", role: "list" });
  const box = h("div", { className: "assist-box", "aria-live": "polite" });
  const editable = canEdit(ctx.role ?? (task.projectId ? null : "owner"));
  const section = h("section", { className: "extra-section", "aria-labelledby": "subtasks-title" }, h("h3", { className: "headline", id: "subtasks-title" }, "الخطوات"), list);
  let children = [];

  const drawList = () => {
    list.replaceChildren(
      ...(children.length
        ? children.map((t) => h("li", { className: `callout subtask${isOpen(t) ? "" : " is-done"}` }, h("span", { className: "zm-sr" }, isOpen(t) ? "" : "منجزة: "), t.title))
        : [h("li", { className: "callout muted" }, "لا خطوات بعد.")]),
    );
  };

  const loadChildren = async () => {
    try {
      const { tasks } = await boardApi.tasks({ projectId: task.projectId ?? "inbox" });
      children = tasks.filter((t) => t.parentId === task.id).sort(byManualOrder);
    } catch {
      children = [];
    }
    if (ctx.isCurrent()) drawList();
  };
  list.append(h("li", { className: "callout muted" }, "تُحمَّل الخطوات…"));
  loadChildren();

  if (!editable) return section;
  const ask = Button({ variant: "secondary" }, "تقسيم إلى خطوات");
  section.append(h("div", { className: "assist-row" }, ask), box);

  ask.addEventListener("click", async () => {
    ask.disabled = true;
    box.replaceChildren(h("p", { className: "callout muted", role: "status" }, "يقسّم المساعد المهمة…"));
    try {
      const { subtasks } = await assistantApi.breakdown(task.id);
      if (!ctx.isCurrent()) return;
      showSteps(subtasks ?? []);
    } catch (error) {
      if (error.status === 401 || !ctx.isCurrent()) return;
      box.replaceChildren(h("p", { className: "callout assist-error", role: "alert" }, problem(error, ctx)));
    } finally {
      ask.disabled = false;
    }
  });

  function showSteps(titles) {
    if (titles.length === 0) {
      box.replaceChildren(h("p", { className: "callout muted", role: "status" }, "لم يقترح المساعد خطوات لهذه المهمة."));
      return;
    }
    const boxes = titles.map((title, i) =>
      h("li", null, h("label", { className: "step choice callout" }, h("input", { type: "checkbox", checked: true, value: String(i) }), h("span", null, title))),
    );
    const error = h("p", { className: "callout field-error", role: "alert" });
    const accept = Button({ variant: "primary" }, "إضافة");
    const dismiss = Button({ variant: "quiet" }, "تجاهل");
    dismiss.addEventListener("click", () => {
      box.replaceChildren();
      ask.focus();
    });
    accept.addEventListener("click", async () => {
      const chosen = boxes.filter((li) => li.querySelector("input").checked).map((li) => titles[Number(li.querySelector("input").value)]);
      if (chosen.length === 0) {
        error.textContent = "اختر خطوة واحدة على الأقل، أو تجاهل الاقتراح.";
        return;
      }
      error.textContent = "";
      accept.disabled = true;
      try {
        let order = after(children.map((t) => t.sortOrder ?? 0));
        for (const title of chosen) {
          ctx.markLocalChange?.();
          await boardApi.createTask({ title, parentId: task.id, projectId: task.projectId ?? null, sortOrder: order++ });
        }
        box.replaceChildren();
        ctx.announce(`أُضيفت ${chosenCount(chosen.length)}.`);
        await loadChildren();
        ask.focus();
      } catch (failure) {
        if (failure.status !== 401) error.textContent = ctx.errorText(failure);
        accept.disabled = false;
        await loadChildren();
      }
    });
    box.replaceChildren(
      AISuggestion({}, [h("p", null, breakdownText(titles.length)), h("ul", { className: "step-list", role: "list" }, boxes)], [accept, dismiss]),
      error,
    );
    boxes[0]?.querySelector("input")?.focus();
  }

  return section;
}

/** «خطوة واحدة» → «أُضيفت خطوة واحدة», «٣ خطوات» → «أُضيفت ٣ خطوات». */
function chosenCount(n) {
  if (n === 1) return "خطوة واحدة";
  if (n === 2) return "خطوتان";
  return n <= 10 ? `${arabicNumber(n)} خطوات` : `${arabicNumber(n)} خطوة`;
}
