// The assistant on the web, as in the Apple app (AssistantViews.swift): «اقتراح بالمساعد» and
// «إملاء» (the title from speech, then the same suggestion) in the add-task form, «تقسيم إلى
// خطوات» in a task's details, and «ملخص اليوم» on Today. Nothing is saved before the person accepts:
// the suggestion card (design/components/AISuggestion) offers «إضافة», «تعديل» (fills the form) and «تجاهل».
// Plain DOM through h() and textContent; nothing here parses HTML.
import { Button, h, icons } from "./lib/components.js";
import { icon } from "./lib/icons.js";
import { assistantErrorText, breakdownText, isoWithOffset, suggestionLines, suggestionToTask } from "./lib/assistant.js";
import { dictatedTitle, dictationErrorText, dictationPrefix, transcriptOf } from "./lib/dictation.js";
import { assistantApi, boardApi, remindersApi } from "./lib/feature-api.js";
import { after, byManualOrder } from "./lib/order.js";
import { newReminder } from "./lib/reminders.js";
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
  box: null,
  button: null,
  hint: null,
  run: 0,
  getCtx: null,
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
  add.getCtx = getCtx;
  setupDictation();
  field.after(h("div", { className: "field assist" }, h("div", { className: "assist-row" }, add.button, dictation.button), dictation.status, add.hint, add.box));
  add.button.addEventListener("click", () => suggest(getCtx()));
  // Closing the sheet (إلغاء, Esc, or adding) stops listening without asking the assistant.
  document.getElementById("add-dialog")?.addEventListener("close", stopDictation);
}

/** Clears the card and anything kept from it, when the dialog opens again. */
export function resetAddAssistant() {
  stopDictation();
  add.run++;
  add.box?.replaceChildren();
  if (add.button) add.button.disabled = false;
}

/** «اقتراح بالمساعد» for what is in the title now, as after dictation. */
export function suggestFromTitle() {
  if (add.ready && add.getCtx) return suggest(add.getCtx());
}

// ——— «إملاء»: the title from speech (AddTaskView.swift) ———

const dictation = {
  button: null,
  status: null,
  /** The SpeechRecognition listening now; null when idle or after a cancel. */
  recognition: null,
};

const speechRecognition = () => (typeof window === "undefined" ? null : (window.SpeechRecognition ?? window.webkitSpeechRecognition ?? null));

function setupDictation() {
  dictation.button = Button({ variant: "quiet", className: "dictate-button", hidden: !speechRecognition() });
  dictation.status = h("p", { className: "callout muted dictate-status", "aria-live": "polite" });
  dictation.button.addEventListener("click", toggleDictation);
  showListening(false);
}

function showListening(listening) {
  dictation.button.replaceChildren(icon(listening ? "stop-circle" : "mic", { size: "sm" }), listening ? "إيقاف الإملاء" : "إملاء");
  dictation.status.textContent = listening ? "أستمع… قل المهمة كما تقولها لشخص." : "";
}

/** Stops listening and keeps the words heard so far, without asking the assistant. */
function stopDictation() {
  const recognition = dictation.recognition;
  if (!recognition) return;
  dictation.recognition = null;
  recognition.abort();
  showListening(false);
}

function toggleDictation() {
  // «إيقاف الإملاء»: stop, and the end below asks the assistant.
  if (dictation.recognition) {
    dictation.recognition.stop();
    return;
  }
  const Recognition = speechRecognition();
  if (!Recognition) return;
  const titleInput = document.getElementById("add-title-input");
  const prefix = dictationPrefix(titleInput.value);
  const recognition = new Recognition();
  recognition.lang = "ar-SA";
  recognition.interimResults = true;
  recognition.continuous = false;
  let failed = false;
  // A new sentence replaces the last suggestion, as the app sets the assistant back to idle.
  add.run++;
  add.box.replaceChildren();
  add.button.disabled = false;

  recognition.addEventListener("result", (event) => {
    if (dictation.recognition !== recognition) return;
    titleInput.value = dictatedTitle(prefix, transcriptOf(event.results));
    titleInput.dispatchEvent(new Event("input", { bubbles: true }));
  });
  recognition.addEventListener("error", (event) => {
    const text = dictationErrorText(event.error);
    if (!text || dictation.recognition !== recognition) return;
    failed = true;
    add.box.replaceChildren(h("p", { className: "callout assist-error", role: "alert" }, text));
  });
  recognition.addEventListener("end", () => {
    if (dictation.recognition !== recognition) return; // cancelled: the sheet closed
    dictation.recognition = null;
    showListening(false);
    dictation.button.focus();
    // The dictated sentence goes to the assistant when it can be reached; otherwise it stays in
    // the title, ready to add as it is.
    if (!failed && titleInput.value.trim() && online()) suggestFromTitle();
  });

  try {
    recognition.start();
  } catch {
    add.box.replaceChildren(h("p", { className: "callout assist-error", role: "alert" }, dictationErrorText("start")));
    return;
  }
  dictation.recognition = recognition;
  showListening(true);
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

/**
 * Where an accepted suggestion goes, as AddTaskView.accept decides it: the project it names when
 * the form lists it (one the person can add to), otherwise the project chosen in the form.
 */
function withFormProject(task) {
  const select = document.getElementById("add-project");
  const known = task.projectId && [...select.options].some((o) => o.value === task.projectId) ? task.projectId : null;
  return { ...task, projectId: known ?? (select.value || null) };
}

/** The sentence after adding a task whose «عند الموعد» could not be added with it (main.js says the same). */
export const AT_TIME_FAILED = "أُضيفت المهمة، ولم يُضف تذكير «عند الموعد». أضفه من تفاصيلها.";

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
      const created = await boardApi.createTask(withFormProject(task));
      // A task with a time reminds at it, as the app adds «عند الموعد» (ensureAtTimeReminder). The
      // task is added either way; a reminder that could not be is said, so it can be added by hand.
      let reminderFailed = false;
      if (created.dueTime || created.duePrayer) {
        await remindersApi.add(newReminder(created.id, { kind: "relative", offsetMinutes: 0 })).catch((e) => (reminderFailed = e.status !== 401));
      }
      document.getElementById("add-dialog").close();
      if (!reminderFailed) ctx.announce("أُضيفت المهمة.");
      await ctx.refreshProjects();
      await ctx.render();
      if (reminderFailed) ctx.showError(AT_TIME_FAILED); // an alert, read out after the redraw
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

/** «تعديل»: the suggestion into the form's fields; main.js's add sheet follows them as if typed. */
function fillForm(task) {
  document.getElementById("add-form").dispatchEvent(new CustomEvent("zimam:fill", { detail: task }));
}

// ——— «ملخص اليوم» on Today ———

/** One summary per day for this page's life, so a live reload keeps it. */
const summaries = new Map();

/** Forgets the summaries when the account signs out, so the next account never sees them. */
export function forgetSummaries() {
  summaries.clear();
}

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
 * «المهام الفرعية» (TaskSubtasksSection.swift): each with its completion circle and opening on its
 * own, «مهمة فرعية جديدة», then «تقسيم إلى خطوات». `ctx`: { primary, today, role, announce,
 * errorText, isCurrent(), openTask(task) } where isCurrent() is false once the pane shows another task.
 * `reload()` on the section reads the subtasks again (another member may have added some).
 */
export function breakdownSection(task, ctx) {
  const list = h("ul", { className: "subtask-list", role: "list" });
  const box = h("div", { className: "assist-box", "aria-live": "polite" });
  const editable = canEdit(ctx.role ?? (task.projectId ? null : "owner"));
  const listError = h("p", { className: "callout field-error", role: "alert" });
  const section = h("section", { className: "extra-section", "aria-labelledby": "subtasks-title" }, h("h3", { className: "headline", id: "subtasks-title" }, "المهام الفرعية"), list, listError);
  let children = [];
  /** Whether `children` is what the server has: new ones are ordered after them only then. */
  let loaded = false;

  const subtaskRow = (t) => {
    const done = !isOpen(t);
    const check = h(
      "button",
      { type: "button", className: `zm-check${done ? " zm-check-on" : ""}`, "aria-pressed": String(done), "aria-label": `${done ? "إلغاء إنجاز" : "إنجاز"}: ${t.title}`, disabled: !editable },
      done ? icons.check() : null,
    );
    check.addEventListener("click", async () => {
      listError.textContent = "";
      check.disabled = true;
      try {
        ctx.markLocalChange?.();
        Object.assign(t, done ? await boardApi.patchTask(t.id, { status: "todo" }) : await boardApi.completeTask(t.id));
        ctx.announce(done ? "أُعيدت المهمة الفرعية إلى المفتوحة." : "أُنجزت المهمة الفرعية.");
        if (ctx.isCurrent()) drawList();
      } catch (failure) {
        check.disabled = false;
        if (failure.status !== 401) listError.textContent = ctx.errorText(failure);
      }
    });
    const open = h("button", { type: "button", className: "subtask-open callout" }, t.title);
    open.addEventListener("click", () => ctx.openTask?.(t));
    return h("li", { className: `subtask${done ? " is-done" : ""}` }, check, open);
  };

  const drawList = () => {
    list.replaceChildren(...(children.length ? children.map(subtaskRow) : [h("li", { className: "callout muted" }, "لا مهام فرعية بعد.")]));
  };

  /** → whether the subtasks were read; a failure says so instead of «لا مهام فرعية بعد». */
  const loadChildren = async () => {
    try {
      const { tasks } = await boardApi.tasks({ projectId: task.projectId ?? "inbox" });
      children = tasks.filter((t) => t.parentId === task.id).sort(byManualOrder);
      loaded = true;
    } catch (failure) {
      if (failure.status === 401 || !ctx.isCurrent()) return false;
      if (!loaded) list.replaceChildren();
      listError.textContent = ctx.errorText(failure);
      return false;
    }
    if (ctx.isCurrent()) {
      listError.textContent = "";
      drawList();
    }
    return true;
  };
  section.reload = () => loadChildren();
  list.append(h("li", { className: "callout muted" }, "تُحمَّل الخطوات…"));
  loadChildren();

  if (!editable) return section;

  // «مهمة فرعية جديدة» with a quiet «إضافة», as in the app.
  const newTitle = h("input", { className: "input body", type: "text", maxlength: "500", placeholder: "مهمة فرعية جديدة", "aria-label": "مهمة فرعية جديدة", enterkeyhint: "done" });
  const addSub = Button({ variant: "quiet", type: "submit" }, "إضافة");
  const addForm = h("form", { className: "subtask-add" }, newTitle, addSub);
  addForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const title = newTitle.value.trim();
    if (!title) return;
    addSub.disabled = true;
    // Ordered after the subtasks the server has, so they are read first if they were not.
    if (!loaded && !(await loadChildren())) {
      addSub.disabled = false;
      return;
    }
    listError.textContent = "";
    try {
      ctx.markLocalChange?.();
      await boardApi.createTask({ title, parentId: task.id, projectId: task.projectId ?? null, sortOrder: after(children.map((t) => t.sortOrder ?? 0)) });
      newTitle.value = "";
      ctx.announce("أُضيفت المهمة الفرعية.");
      await loadChildren();
      newTitle.focus();
    } catch (failure) {
      if (failure.status !== 401) listError.textContent = ctx.errorText(failure);
    } finally {
      addSub.disabled = false;
    }
  });

  const ask = h("button", { type: "button", className: "zm-btn zm-btn-quiet assist-ask" }, icon("summary", { size: "sm" }), "تقسيم إلى خطوات");
  section.append(addForm, h("div", { className: "assist-row" }, ask), box);

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
      if (!loaded && !(await loadChildren())) {
        accept.disabled = false;
        return;
      }
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
