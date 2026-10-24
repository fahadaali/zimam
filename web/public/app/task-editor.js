// The open task as a form, section by section as TaskDetailView.swift: the title, notes and tags;
// «الموعد» with «الوقت» (all day, a clock time, or around a prayer); «التذكيرات»; the priority and
// project; and «التكرار». Each field saves when it is left or changed (PATCH /v1/tasks/:id), as the
// app saves on leaving a field. Those who cannot edit the task get the read-only details instead
// (task-pane.js). Plain DOM through h() and textContent.
import { Button, IconButton, PrayerChip, h } from "./lib/components.js";
import { dualDateWithYear, isIsoDate, timeLabel } from "./lib/dates.js";
import { remindersApi } from "./lib/feature-api.js";
import { icon } from "./lib/icons.js";
import { PRAYERS, PRAYER_NAMES, prayerPhrase } from "./lib/prayer.js";
import { WEEKDAYS, WEEKDAY_NAMES, chooseFrequency, ruleChoice, ruleText, toggleWeekday } from "./lib/recurrence.js";
import { hasTaskTime, localToIso, newReminder, presetsFor, reminderLabel, sortReminders } from "./lib/reminders.js";
import { PRIORITY_NAMES } from "./lib/tasks.js";

let fieldIds = 0;
const uid = (name) => `te-${name}-${++fieldIds}`;

/** A grouped card of rows, as a Form section: an optional heading, the rows, an optional footer. */
function card(title, rows, footer) {
  const titleId = title ? uid("section") : null;
  return h(
    "section",
    { className: "form-section", "aria-labelledby": titleId },
    title ? h("h3", { className: "caption muted form-section-title", id: titleId }, title) : null,
    h("div", { className: "form-card" }, rows),
    footer ? h("p", { className: "caption muted form-footer" }, footer) : null,
  );
}

/** A row with its label at the inline start and its control at the end. */
function row(label, control, { id } = {}) {
  return h("div", { className: "form-row" }, h("label", { className: "body form-label", for: id }, label), control);
}

/** A segmented choice («طوال اليوم / ساعة / صلاة»), as the app's segmented pickers. */
function segmented(label, options, current, onPick) {
  return h(
    "div",
    { className: "segmented form-segmented", role: "group", "aria-label": label },
    options.map(([value, text]) =>
      h("button", { type: "button", className: "segment callout", dataset: { key: `seg-${label}-${value}` }, "aria-pressed": String(value === current), onclick: () => value !== current && onPick(value) }, text),
    ),
  );
}

/** «قبل العصر بـ١٠ د» between − and +, five minutes a step, from 120 before to 120 after (Stepper). */
function prayerStepper(prayer, offset, onChange) {
  const minus = IconButton({ icon: "minus", label: "قبل بخمس دقائق", dataset: { key: "step-minus" }, disabled: offset <= -120, onclick: () => onChange(Math.max(-120, offset - 5)) });
  const plus = IconButton({ icon: "plus", label: "بعد بخمس دقائق", dataset: { key: "step-plus" }, disabled: offset >= 120, onclick: () => onChange(Math.min(120, offset + 5)) });
  return h("div", { className: "stepper" }, minus, h("span", { "aria-live": "polite" }, PrayerChip(prayerPhrase(prayer, offset))), plus);
}

function prayerSelect(current, onChange, id) {
  return h(
    "select",
    { className: "input body form-control", id, dataset: { key: "prayer" }, onchange: (e) => onChange(e.target.value) },
    PRAYERS.map((p) => h("option", { value: p, selected: p === current }, PRAYER_NAMES[p])),
  );
}

/** An hour from now, on the hour, as the app starts a clock time: "15:00" at 2:20 p.m. */
function nextHour(now = new Date()) {
  return `${String((now.getHours() + 1) % 24).padStart(2, "0")}:00`;
}

/**
 * The editor for `task`. `ctx`: { primary, today, projects (those the person can add to),
 * projectName(id), save(fields) → Promise<task>, isCurrent(), announce, errorText, error (the error
 * line, kept across redraws), ensureAtTimeReminder() }.
 * `remindersNode` is the «التذكيرات» section (remindersSection), kept across redraws so its list is
 * read once per opened task. Controls carry `data-key`, so a redraw can give focus back.
 */
export function taskEditor(task, ctx, remindersNode) {
  const error = ctx.error ?? h("p", { className: "callout field-error", role: "alert" });

  /** → whether the server took the change */
  async function save(fields, { announce } = {}) {
    error.textContent = "";
    try {
      await ctx.save(fields);
      if (announce) ctx.announce(announce);
      return true;
    } catch (failure) {
      if (failure.status !== 401 && ctx.isCurrent()) error.textContent = ctx.errorText(failure);
      return false;
    }
  }

  // ——— Title, notes, tags ———

  const titleId = uid("title");
  const title = h("input", { className: "input headline form-plain", id: titleId, dataset: { key: "title" }, value: task.title, maxlength: "500", "aria-label": "عنوان المهمة", placeholder: "عنوان المهمة", enterkeyhint: "done" });
  title.addEventListener("change", () => {
    const value = title.value.trim();
    if (!value) {
      title.value = task.title;
      error.textContent = "اكتب عنوان المهمة.";
      return;
    }
    if (value !== task.title) save({ title: value });
  });
  title.addEventListener("keydown", (e) => e.key === "Enter" && title.blur());

  const notes = h("textarea", { className: "input body form-plain form-notes", dataset: { key: "notes" }, rows: "3", maxlength: "20000", "aria-label": "ملاحظات", placeholder: "ملاحظات" });
  notes.value = task.notes ?? "";
  notes.addEventListener("change", () => {
    const value = notes.value.trim() ? notes.value : null;
    if (value !== (task.notes ?? null)) save({ notes: value });
  });

  const tags = h("input", { className: "input callout form-plain", dataset: { key: "tags" }, value: (task.tags ?? []).join("، "), "aria-label": "الوسوم، مفصولة بفاصلة", placeholder: "الوسوم، مفصولة بفاصلة", maxlength: "1600" });
  tags.addEventListener("change", () => {
    const list = [...new Set(tags.value.split(/[,،]/).map((t) => t.trim()).filter(Boolean))].slice(0, 30);
    if (list.join("\u0000") !== (task.tags ?? []).join("\u0000")) save({ tags: list });
  });

  const text = card(null, [title, notes, tags]);

  // ——— «الموعد» ———

  const dueRows = [];
  const hasDue = !!task.dueDate;
  const dueToggleId = uid("due");
  const dueToggle = h("input", { type: "checkbox", className: "switch", id: dueToggleId, dataset: { key: "due" }, role: "switch", checked: hasDue });
  dueToggle.addEventListener("change", () => {
    if (dueToggle.checked) save({ dueDate: ctx.today });
    else save({ dueDate: null, startDate: null, dueTime: null });
  });
  dueRows.push(row("تاريخ الاستحقاق", dueToggle, { id: dueToggleId }));
  if (hasDue) {
    const dateId = uid("date");
    const date = h("input", { type: "date", className: "input body form-control", id: dateId, dataset: { key: "date" }, value: task.dueDate });
    date.addEventListener("change", () => {
      if (!isIsoDate(date.value)) {
        date.value = task.dueDate;
        return;
      }
      if (date.value === task.dueDate) return;
      // A start date after the new day would no longer hold: the task becomes one day.
      const fields = { dueDate: date.value };
      if (task.startDate && task.startDate > date.value) fields.startDate = null;
      save(fields);
    });
    dueRows.push(row("التاريخ", date, { id: dateId }));
    dueRows.push(h("p", { className: "caption muted form-note" }, dualDateWithYear(task.dueDate, { primary: ctx.primary })));
  }

  const mode = task.duePrayer ? "prayer" : task.dueTime ? "clock" : "allDay";
  // From all day to a time adds «عند الموعد», as Store.setTime does: a time set is one to be told of.
  const timed = async (fields) => {
    if ((await save(fields)) && mode === "allDay" && ctx.isCurrent()) ctx.ensureAtTimeReminder?.();
  };
  dueRows.push(
    h(
      "div",
      { className: "form-row form-row-stack" },
      h("span", { className: "body form-label" }, "الوقت"),
      segmented("الوقت", [["allDay", "طوال اليوم"], ["clock", "ساعة"], ["prayer", "صلاة"]], mode, (value) => {
        if (value === "allDay") save({ dueTime: null, duePrayer: null, duePrayerOffset: null });
        else if (value === "clock") {
          if (!task.dueDate) {
            error.textContent = "حدّد تاريخ الاستحقاق أولاً لتختار ساعة.";
            return;
          }
          timed({ dueTime: nextHour(), duePrayer: null, duePrayerOffset: null });
        } else timed({ duePrayer: "asr", duePrayerOffset: 0, dueTime: null });
      }),
    ),
  );
  if (mode === "clock") {
    const clockId = uid("clock");
    const clock = h("input", { type: "time", className: "input body form-control", id: clockId, dataset: { key: "clock" }, value: task.dueTime, step: "300" });
    clock.addEventListener("change", () => {
      if (/^\d{2}:\d{2}$/.test(clock.value) && clock.value !== task.dueTime) save({ dueTime: clock.value });
    });
    dueRows.push(row("الساعة", clock, { id: clockId }));
  }
  if (mode === "prayer") {
    const prayerId = uid("prayer");
    const offset = task.duePrayerOffset ?? 0;
    dueRows.push(row("الصلاة", prayerSelect(task.duePrayer, (p) => save({ duePrayer: p }), prayerId), { id: prayerId }));
    dueRows.push(h("div", { className: "form-row" }, prayerStepper(task.duePrayer, offset, (o) => save({ duePrayerOffset: o }))));
    dueRows.push(
      h(
        "p",
        { className: "caption muted form-note" },
        task.dueDate ? `تتبع وقت ${PRAYER_NAMES[task.duePrayer]} في يومها.` : `تتبع وقت ${PRAYER_NAMES[task.duePrayer]} كل يوم.`,
      ),
    );
  }
  const due = card("الموعد", dueRows);

  // ——— Priority and project ———

  const priorityId = uid("priority");
  const priority = h(
    "select",
    { className: "input body form-control", id: priorityId, dataset: { key: "priority" }, onchange: (e) => save({ priority: Number(e.target.value) }) },
    [0, 1, 2, 3].map((level) => h("option", { value: String(level), selected: level === (task.priority ?? 0) }, PRIORITY_NAMES[level])),
  );
  const detailRows = [row("الأولوية", priority, { id: priorityId })];
  // A subtask goes with its task (TaskDetailsSection.swift hides the picker for subtasks).
  if (!task.parentId) {
    const projectId = uid("project");
    const options = [...ctx.projects];
    if (task.projectId && !options.some((p) => p.id === task.projectId)) options.push({ id: task.projectId, name: ctx.projectName(task.projectId) ?? "مشروع مشترك" });
    const project = h(
      "select",
      {
        className: "input body form-control",
        id: projectId,
        dataset: { key: "project" },
        onchange: (e) => {
          const next = e.target.value || null;
          const name = next ? options.find((p) => p.id === next)?.name : "صندوق المهام";
          save({ projectId: next, sectionId: null }, { announce: `نُقلت المهمة إلى ${name}.` });
        },
      },
      h("option", { value: "", selected: !task.projectId }, "صندوق المهام"),
      options.map((p) => h("option", { value: p.id, selected: p.id === task.projectId }, p.name)),
    );
    detailRows.push(row("المشروع", project, { id: projectId }));
  }
  const details = card(null, detailRows);

  // ——— «التكرار» ———

  const choice = ruleChoice(task.recurrence);
  const repeatId = uid("repeat");
  const repeat = h(
    "select",
    {
      className: "input body form-control",
      id: repeatId,
      dataset: { key: "repeat" },
      onchange: (e) => {
        if (e.target.value === "custom") return;
        save({ recurrence: chooseFrequency(task.recurrence, e.target.value, task.dueDate) });
      },
    },
    [["off", "بلا تكرار"], ["DAILY", "يومياً"], ["WEEKLY", "أسبوعياً"], ["MONTHLY", "شهرياً"], ["YEARLY", "سنوياً"], ...(choice === "custom" ? [["custom", "تكرار مخصص"]] : [])].map(([v, t]) =>
      h("option", { value: v, selected: v === choice }, t),
    ),
  );
  const repeatRows = [row("التكرار", repeat, { id: repeatId })];
  if (choice === "WEEKLY") {
    const days = new Set(task.recurrence.match(/BYDAY=([A-Z,]+)/)?.[1]?.split(",") ?? []);
    repeatRows.push(
      h(
        "div",
        { className: "weekday-grid", role: "group", "aria-label": "أيام التكرار" },
        WEEKDAYS.map((day) =>
          h("button", { type: "button", className: "weekday callout", dataset: { key: `day-${day}` }, "aria-pressed": String(days.has(day)), onclick: () => save({ recurrence: toggleWeekday(task.recurrence, day) }) }, WEEKDAY_NAMES[day]),
        ),
      ),
    );
  }
  const described = ruleText(task.recurrence);
  if (described) repeatRows.push(h("p", { className: "caption muted form-note" }, described));
  const recurrence = card(null, repeatRows);

  const node = h("div", { className: "task-editor" }, text, due, remindersNode, details, recurrence, error);
  return node;
}

/**
 * «التذكيرات»: the person's own reminders on the task, read once (GET /v1/tasks/:id/reminders) and
 * changed through sync. `getTask()` is the task as it is now, as its time decides the presets.
 */
export function remindersSection(taskId, getTask, ctx) {
  const list = h("div", { className: "reminder-list" }, h("p", { className: "caption muted form-note" }, "تُحمَّل التذكيرات…"));
  const error = h("p", { className: "callout field-error", role: "alert" });
  const footer = h("p", { className: "caption muted form-footer" });
  const menuId = uid("reminder-menu");
  const menu = h("div", { className: "reminder-menu account-menu", id: menuId, popover: "auto" });
  const add = h(
    "button",
    { type: "button", className: "zm-btn zm-btn-quiet form-add", popovertarget: menuId, "aria-haspopup": "true" },
    icon("bell", { size: "sm" }),
    "إضافة تذكير",
  );
  const form = h("div", { className: "reminder-form" });
  const section = card("التذكيرات", [list, form, add, menu]);
  section.append(error, footer);
  let reminders = [];
  /** Whether `reminders` is the list the server has. */
  let read = false;

  menu.addEventListener("beforetoggle", (event) => {
    if (event.newState !== "open") return;
    const rect = add.getBoundingClientRect();
    menu.style.setProperty("--menu-top", `${Math.min(rect.bottom + 4, window.innerHeight - 320)}px`);
    menu.style.setProperty("--menu-end", `${document.documentElement.dir === "rtl" ? rect.left : window.innerWidth - rect.right}px`);
    fillMenu();
  });

  function fillMenu() {
    const task = getTask();
    const item = (label, iconName, onclick) =>
      h("li", null, h("button", { type: "button", className: "menu-row callout", onclick: () => (menu.hidePopover(), onclick()) }, iconName ? icon(iconName) : null, label));
    const presets = hasTaskTime(task) ? presetsFor(task, reminders) : [];
    menu.replaceChildren(
      h(
        "ul",
        { className: "menu-list", role: "list" },
        presets.map((offset) => item(relativeLabel(offset), null, () => addReminder({ kind: "relative", offsetMinutes: offset }))),
        item("في وقت آخر…", "calendar-clock", showTimeForm),
        item("عند صلاة…", "moon-star", showPrayerForm),
      ),
    );
  }

  const relativeLabel = (offset) => reminderLabel({ kind: "relative", offsetMinutes: offset }).text;

  function formatTime(at) {
    const date = new Date(at);
    if (Number.isNaN(date.getTime())) return at;
    const day = date.toLocaleDateString("en-CA");
    return `${dualDateWithYear(day, { primary: ctx.primary })}، ${timeLabel(date.toTimeString().slice(0, 5))}`;
  }

  function draw() {
    const task = getTask();
    list.replaceChildren(
      ...sortReminders(reminders).map((r) => {
        const label = reminderLabel(r, { formatTime });
        const text = label.kind === "prayer" ? PrayerChip(label.text) : h("span", { className: "body" }, label.text);
        const remove = IconButton({ icon: "trash", label: `حذف التذكير ${label.text}`, className: "danger", onclick: () => removeReminder(r) });
        return h("div", { className: "form-row reminder-row" }, h("span", { className: "reminder-text" }, label.kind === "prayer" ? null : icon("bell", { size: "sm" }), text), remove);
      }),
    );
    if (reminders.length === 0) list.replaceChildren();
    footer.textContent = hasTaskTime(task)
      ? task.dueDate
        ? "تصلك التذكيرات على أجهزتك التي فيها زمام. تذكير المكان يُضاف من التطبيق."
        : "تذكير الصلاة لمهمة بلا تاريخ يتكرر كل يوم."
      : "حدّد موعداً للمهمة لتختار «عند الموعد» أو «قبل الموعد».";
  }

  async function load() {
    try {
      ({ reminders } = await remindersApi.list(taskId));
      read = true;
    } catch (failure) {
      reminders = [];
      if (failure.status !== 401 && ctx.isCurrent()) error.textContent = ctx.errorText(failure);
    }
    if (ctx.isCurrent()) draw();
  }

  /** `quiet`: added for the person (ensureAtTime), so the focus and an open form stay where they are. */
  async function addReminder(fields, { quiet = false } = {}) {
    error.textContent = "";
    const reminder = newReminder(taskId, fields);
    try {
      ctx.markLocalChange?.();
      await remindersApi.add(reminder);
      reminders.push(reminder);
      if (!quiet) {
        ctx.announce("أُضيف التذكير.");
        form.replaceChildren();
      }
      if (ctx.isCurrent()) draw();
      if (!quiet) add.focus();
    } catch (failure) {
      if (failure.status !== 401 && ctx.isCurrent()) error.textContent = ctx.errorText(failure);
    }
  }

  /** «عند الموعد», unless a reminder counts from the task's time already (ensureAtTimeReminder). */
  async function ensureAtTime() {
    await loading;
    const task = getTask();
    if (!read || (!task.dueTime && !task.duePrayer)) return;
    if (reminders.some((r) => r.kind === "relative")) return;
    await addReminder({ kind: "relative", offsetMinutes: 0 }, { quiet: true });
  }

  async function removeReminder(reminder) {
    error.textContent = "";
    try {
      ctx.markLocalChange?.();
      await remindersApi.remove(reminder);
      reminders = reminders.filter((r) => r.id !== reminder.id);
      ctx.announce("حُذف التذكير.");
      if (ctx.isCurrent()) draw();
      add.focus();
    } catch (failure) {
      if (failure.status !== 401 && ctx.isCurrent()) error.textContent = ctx.errorText(failure);
    }
  }

  /** «تذكير في وقت آخر»: a date and time of its own, which stays if the task moves. */
  function showTimeForm() {
    const id = uid("at");
    const start = new Date(Date.now() + 3600_000);
    const pad = (n) => String(n).padStart(2, "0");
    const value = `${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())}T${pad(start.getHours())}:00`;
    const input = h("input", { type: "datetime-local", className: "input body", id, value, min: value.slice(0, 10) + "T00:00" });
    const preview = h("p", { className: "caption muted" });
    const update = () => (preview.textContent = isIsoDate(input.value.slice(0, 10)) ? dualDateWithYear(input.value.slice(0, 10), { primary: ctx.primary }) : "");
    input.addEventListener("input", update);
    update();
    const ok = Button({ variant: "primary", onclick: () => {
      const at = localToIso(input.value);
      if (!at || new Date(at).getTime() <= Date.now()) {
        error.textContent = "اختر وقتاً قادماً للتذكير.";
        return;
      }
      addReminder({ kind: "time", at });
    } }, "إضافة");
    const cancel = Button({ variant: "quiet", onclick: () => (form.replaceChildren(), add.focus()) }, "إلغاء");
    form.replaceChildren(
      h("div", { className: "reminder-sheet" },
        h("label", { className: "headline", for: id }, "تذكير في وقت آخر"),
        input, preview,
        h("p", { className: "caption muted" }, "يبقى في وقته ولو تغيّر موعد المهمة."),
        h("div", { className: "sheet-actions" }, ok, cancel)),
    );
    input.focus();
  }

  /** «تذكير عند صلاة»: a prayer and how long before or after it. */
  function showPrayerForm() {
    const id = uid("rp");
    let prayer = "asr";
    let offset = 0;
    const stepperSlot = h("div");
    const drawStepper = () => stepperSlot.replaceChildren(prayerStepper(prayer, offset, (o) => ((offset = o), drawStepper())));
    drawStepper();
    const select = prayerSelect(prayer, (p) => ((prayer = p), drawStepper()), id);
    const ok = Button({ variant: "primary", onclick: () => addReminder({ kind: "prayer", prayer, offsetMinutes: offset }) }, "إضافة");
    const cancel = Button({ variant: "quiet", onclick: () => (form.replaceChildren(), add.focus()) }, "إلغاء");
    form.replaceChildren(
      h("div", { className: "reminder-sheet" },
        h("label", { className: "headline", for: id }, "تذكير عند صلاة"),
        select, stepperSlot,
        h("div", { className: "sheet-actions" }, ok, cancel)),
    );
    select.focus();
  }

  const loading = load();
  return { node: section, redraw: () => ctx.isCurrent() && draw(), ensureAtTime };
}
