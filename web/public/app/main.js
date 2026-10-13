// زمام على الويب: sign in with Apple, then Today, Upcoming, Projects and Search over the REST API.
// Plain DOM and ES modules; views are chosen by the URL hash (#/today, #/projects/<id>, …).
import { api, errorText, session, whenSignedOut } from "./lib/api.js";
import { Button, ButtonLink, PrayerChip, ProjectCard, TaskRow, h, setRowDone } from "./lib/components.js";
import { addDays, dayHeading, dualDate, dueChip, isIsoDate, localIsoDate, relativeDay, weekdayName } from "./lib/dates.js";
import { randomNonce, sha256Hex } from "./lib/nonce.js";
import { arabicNumber, parseDigits } from "./lib/numbers.js";
import { prayerPhrase } from "./lib/prayer.js";
import { PRIORITY_WORDS, groupByDay, isOpen, priorityKey, progressText, splitToday, taskCount } from "./lib/tasks.js";

const APPLE_CLIENT_ID = "app.zimam.web";
const LEAVE_AFTER = 1000; // a completed task stays a second so it can be undone
const FADE = 250;

const $ = (id) => document.getElementById(id);
const els = {
  loading: $("loading"),
  signin: $("signin"),
  signinButton: $("signin-button"),
  signinError: $("signin-error"),
  shell: $("shell"),
  view: $("view"),
  main: $("main"),
  appError: $("app-error"),
  announcer: $("announcer"),
  addButton: $("add-button"),
  signout: $("signout-button"),
};

const state = {
  me: null,
  projects: [],
  today: localIsoDate(),
  renderId: 0,
};

const primary = () => state.me?.settings?.calendar ?? "hijri";
const projectName = (id) => state.projects.find((p) => p.id === id)?.name ?? null;

// ——— Status and errors ———

let announceTimer;
function announce(text) {
  clearTimeout(announceTimer);
  els.announcer.textContent = "";
  announceTimer = setTimeout(() => (els.announcer.textContent = text), 100);
}

function showError(error) {
  els.appError.textContent = typeof error === "string" ? error : errorText(error);
}
function clearError() {
  els.appError.textContent = "";
}

// ——— Sign in ———

let pendingNonce = null;
async function prepareNonce() {
  const raw = randomNonce();
  pendingNonce = { raw, hashed: await sha256Hex(raw), state: randomNonce(16) };
}

function showSignIn(message = "") {
  els.loading.hidden = true;
  els.shell.hidden = true;
  els.signin.hidden = false;
  els.signinError.textContent = message;
  document.title = "تسجيل الدخول | زمام";
  prepareNonce();
}

// Apple's popup must open inside the click, so the nonce is ready before it.
els.signinButton.addEventListener("click", async () => {
  els.signinError.textContent = "";
  const apple = window.AppleID?.auth;
  if (!apple || !pendingNonce) {
    els.signinError.textContent = "تعذّر تحميل تسجيل الدخول بحساب أبل. تحقق من اتصالك ثم أعد تحميل الصفحة.";
    return;
  }
  const attempt = pendingNonce;
  prepareNonce();
  let result;
  try {
    apple.init({
      clientId: APPLE_CLIENT_ID,
      scope: "",
      redirectURI: `${location.origin}/app`,
      state: attempt.state,
      nonce: attempt.hashed,
      usePopup: true,
    });
    result = await apple.signIn();
  } catch (error) {
    if (error?.error === "popup_closed_by_user" || error?.error === "user_cancelled_authorize") return;
    els.signinError.textContent = "تعذّر تسجيل الدخول بحساب أبل. حاول مرة أخرى.";
    return;
  }

  const idToken = result?.authorization?.id_token;
  if (!idToken || result.authorization.state !== attempt.state) {
    els.signinError.textContent = "تعذّر تسجيل الدخول بحساب أبل. حاول مرة أخرى.";
    return;
  }
  els.signinButton.disabled = true;
  try {
    const { token } = await api.signIn(idToken, attempt.raw);
    session.set(token);
    await start();
  } catch (error) {
    els.signinError.textContent = errorText(error);
  } finally {
    els.signinButton.disabled = false;
  }
});

whenSignedOut(() => showSignIn("انتهت الجلسة. سجّل الدخول مرة أخرى."));

els.signout.addEventListener("click", async () => {
  els.signout.disabled = true;
  try {
    await api.signOut();
  } catch {
    /* the local session goes either way */
  }
  els.signout.disabled = false;
  session.clear();
  state.me = null;
  state.projects = [];
  showSignIn();
});

async function start() {
  if (!session.get()) {
    showSignIn();
    return;
  }
  try {
    [state.me, { projects: state.projects }] = await Promise.all([api.me(), api.projects()]);
  } catch (error) {
    if (error.status === 401) return; // whenSignedOut already showed sign-in
    els.loading.hidden = true;
    els.signin.hidden = true;
    els.shell.hidden = false;
    showError(error);
    return;
  }
  els.loading.hidden = true;
  els.signin.hidden = true;
  els.shell.hidden = false;
  render({ focus: false });
}

// ——— Routing ———

function parseRoute() {
  const hash = location.hash.replace(/^#\/?/, "");
  const [path, search = ""] = hash.split("?");
  const parts = path.split("/").filter(Boolean).map(decodeURIComponent);
  const params = new URLSearchParams(search);
  if (parts[0] === "upcoming") return { name: "upcoming" };
  if (parts[0] === "projects" && parts[1]) return { name: "project", id: parts[1] };
  if (parts[0] === "projects") return { name: "projects" };
  if (parts[0] === "inbox") return { name: "inbox" };
  if (parts[0] === "search") return { name: "search", q: params.get("q") ?? "" };
  return { name: "today" };
}

const NAV = { today: "today", upcoming: "upcoming", projects: "projects", project: "projects", inbox: "projects", search: "search" };

function updateNav(route) {
  for (const link of document.querySelectorAll(".app-nav a")) {
    if (link.dataset.route === NAV[route.name]) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
}

window.addEventListener("hashchange", () => {
  if (!els.shell.hidden) render({ focus: true });
});

const VIEWS = { today: viewToday, upcoming: viewUpcoming, projects: viewProjects, project: viewProject, inbox: viewInbox, search: viewSearch };

async function render({ focus = false } = {}) {
  const id = ++state.renderId;
  state.today = localIsoDate();
  const route = parseRoute();
  updateNav(route);
  clearError();
  let content;
  try {
    content = await VIEWS[route.name](route);
  } catch (error) {
    if (error.status === 401 || id !== state.renderId) return;
    content = [h("h1", { className: "display view-title", tabindex: "-1" }, "زمام"), emptyState("تعذّر تحميل هذه الصفحة.")];
    showError(error);
  }
  if (id !== state.renderId) return; // a newer navigation won
  els.view.replaceChildren(...content);
  const heading = els.view.querySelector("h1");
  document.title = `${heading?.textContent ?? "زمام"} | زمام`;
  if (focus) heading?.focus();
}

// ——— Shared pieces ———

function viewHeader(title, subtitle, ...extra) {
  return h(
    "header",
    { className: "view-header" },
    h("h1", { className: "display view-title", tabindex: "-1" }, title),
    subtitle ? h("p", { className: "callout muted" }, subtitle) : null,
    ...extra,
  );
}

function emptyState(text) {
  return h("p", { className: "body muted empty" }, text);
}

/**
 * A list of TaskRows. `showDate` adds the due-date chip; `leaveWhenDone` removes a task a second
 * after it is completed (open-task lists), so the circle can be tapped again to undo.
 */
function taskList(tasks, { showDate = true, showProject = true, leaveWhenDone = true, label } = {}) {
  const list = h("ul", { className: "task-list", role: "list", "aria-label": label });
  for (const task of tasks) list.append(taskItem(task, { showDate, showProject, leaveWhenDone }));
  return list;
}

function taskItem(task, options) {
  const li = h("li", { className: "task-item" });
  const row = TaskRow({
    title: task.title,
    note: task.notes ? task.notes.split("\n")[0] : null,
    done: task.status === "done",
    priority: priorityKey(task.priority),
    date: options.showDate && task.dueDate ? dueChip(task.dueDate, { today: state.today, primary: primary() }) : null,
    prayer: prayerPhrase(task.duePrayer, task.duePrayerOffset),
    project: options.showProject && task.projectId ? projectName(task.projectId) : null,
    onToggle: () => toggleTask(task, li, row, options),
    onOpen: () => openTask(task, li),
  });
  li.append(row);
  return li;
}

async function toggleTask(task, li, row, { leaveWhenDone }) {
  const done = isOpen(task);
  const previous = task.status;
  task.status = done ? "done" : "todo";
  setRowDone(row, done, task.title);
  clearTimeout(li.leaveTimer);
  li.classList.remove("is-leaving");
  clearError();

  const call = done ? api.completeTask(task.id) : api.reopenTask(task.id);
  if (done && leaveWhenDone) li.leaveTimer = setTimeout(() => leave(li, task), LEAVE_AFTER);
  try {
    Object.assign(task, await call);
    announce(done ? "أُنجزت المهمة." : "أُعيدت المهمة إلى المفتوحة.");
    refreshProjects();
  } catch (error) {
    clearTimeout(li.leaveTimer);
    li.classList.remove("is-leaving");
    task.status = previous;
    setRowDone(row, previous === "done", task.title);
    if (error.status !== 401) showError(error);
  }
}

function leave(li, task) {
  if (isOpen(task) || !li.isConnected) return;
  li.classList.add("is-leaving");
  setTimeout(() => removeItem(li), matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : FADE);
}

/** Removes a task from its list, keeping keyboard focus nearby, and tidies an emptied list. */
function removeItem(li) {
  if (!li.isConnected) return;
  const hadFocus = li.contains(document.activeElement);
  const next = li.nextElementSibling ?? li.previousElementSibling;
  const list = li.parentElement;
  li.remove();
  if (hadFocus) (next?.querySelector(".zm-check") ?? els.view.querySelector("h1"))?.focus();
  if (list && list.children.length === 0) render({ focus: hadFocus });
}

async function refreshProjects() {
  try {
    ({ projects: state.projects } = await api.projects());
  } catch {
    /* counts refresh on the next visit */
  }
}

// ——— Views ———

async function viewToday() {
  const today = state.today;
  const { tasks } = await api.tasks({ status: "open", dueTo: today });
  const { overdue, due } = splitToday(tasks, today);
  const out = [viewHeader("اليوم", `${weekdayName(today)}، ${dualDate(today, { primary: primary(), today })}`)];
  if (tasks.length === 0) {
    out.push(emptyState("لا مهام اليوم. يومك لك."));
    return out;
  }
  if (overdue.length) {
    out.push(
      h("section", { className: "list-section", "aria-labelledby": "overdue-title" },
        h("h2", { className: "headline section-title", id: "overdue-title" }, "متأخرة ", h("span", { className: "caption muted" }, taskCount(overdue.length))),
        taskList(overdue)),
    );
  }
  if (due.length) {
    const list = taskList(due, { showDate: false });
    out.push(
      overdue.length
        ? h("section", { className: "list-section", "aria-labelledby": "due-title" },
            h("h2", { className: "headline section-title", id: "due-title" }, "مهام اليوم ", h("span", { className: "caption muted" }, taskCount(due.length))),
            list)
        : list,
    );
  }
  return out;
}

async function viewUpcoming() {
  const tomorrow = addDays(state.today, 1);
  const { tasks } = await api.tasks({ status: "open", dueFrom: tomorrow });
  const out = [viewHeader("القادم", null)];
  const groups = groupByDay(tasks);
  if (groups.length === 0) {
    out.push(emptyState("لا مهام قادمة. ما بعد اليوم صفحة بيضاء."));
    return out;
  }
  for (const { date, tasks: dayTasks } of groups) {
    const heading = dayHeading(date, { today: state.today, primary: primary() });
    const titleId = `day-${date}`;
    out.push(
      h("section", { className: "list-section", "aria-labelledby": titleId },
        h("hgroup", { className: "day-heading" },
          h("h2", { className: "headline", id: titleId }, heading.title),
          h("p", { className: "caption muted" }, heading.subtitle)),
        taskList(dayTasks, { showDate: false })),
    );
  }
  return out;
}

async function viewProjects() {
  ({ projects: state.projects } = await api.projects());
  const projects = state.projects.filter((p) => p.kind === "project" && !p.archivedAt);
  const out = [viewHeader("المشاريع", null)];
  if (projects.length === 0) out.push(emptyState("لا مشاريع بعد. أنشئ مشروعك الأول من تطبيق زمام."));
  else {
    const grid = h("ul", { className: "project-grid", role: "list" });
    for (const p of projects) {
      grid.append(h("li", null, ProjectCard({ name: p.name, done: p.doneCount ?? 0, total: p.taskCount ?? 0, href: `#/projects/${encodeURIComponent(p.id)}` })));
    }
    out.push(grid);
  }
  out.push(h("p", { className: "inbox-link" }, ButtonLink({ variant: "quiet", href: "#/inbox" }, "مهام بلا مشروع")));
  return out;
}

async function projectTasksView(title, subtitle, projectId) {
  const { tasks } = await api.tasks({ projectId });
  const top = tasks.filter((t) => !t.parentId);
  const open = top.filter(isOpen);
  const done = top.filter((t) => !isOpen(t));
  const back = ButtonLink({ variant: "quiet", href: "#/projects", className: "back-link" }, "المشاريع");
  const out = [h("nav", { className: "breadcrumb", "aria-label": "المسار" }, back), viewHeader(title, subtitle)];
  out.push(open.length ? taskList(open, { showProject: false, label: "المهام المفتوحة" }) : emptyState("لا مهام مفتوحة هنا."));
  if (done.length) {
    out.push(
      h("details", { className: "done-section" },
        h("summary", { className: "headline" }, "المنجزة ", h("span", { className: "caption muted" }, taskCount(done.length))),
        taskList(done, { showProject: false, leaveWhenDone: false, label: "المهام المنجزة" })),
    );
  }
  return out;
}

async function viewProject({ id }) {
  let project = state.projects.find((p) => p.id === id);
  if (!project) project = await api.project(id);
  const counts = project.taskCount != null ? progressText(project.doneCount ?? 0, project.taskCount) : null;
  return projectTasksView(project.name, counts, id);
}

async function viewInbox() {
  return projectTasksView("مهام بلا مشروع", "مهامك التي لا تتبع مشروعاً.", "inbox");
}

async function viewSearch({ q }) {
  const input = h("input", {
    className: "input body",
    id: "search-input",
    name: "q",
    type: "search",
    value: q,
    enterkeyhint: "search",
    autocomplete: "off",
    spellcheck: "false",
    maxlength: "200",
  });
  const form = h(
    "form",
    {
      className: "search-form",
      action: "#/search",
      onsubmit: (event) => {
        event.preventDefault();
        const value = input.value.trim();
        location.hash = value ? `#/search?q=${encodeURIComponent(value)}` : "#/search";
      },
    },
    h("label", { className: "headline", for: "search-input" }, "ابحث في المهام والملاحظات"),
    h("div", { className: "search-row" }, input, Button({ variant: "secondary", type: "submit" }, "بحث")),
  );
  const out = [viewHeader("البحث", null), h("search", null, form)];
  if (!q.trim()) {
    out.push(emptyState("اكتب كلمة من عنوان المهمة أو ملاحظتها."));
    return out;
  }
  const { tasks } = await api.tasks({ q: q.trim() });
  const count = tasks.length === 0 ? "لا نتائج" : tasks.length === 1 ? "نتيجة واحدة" : `${arabicNumber(tasks.length)} نتائج`;
  out.push(h("p", { className: "callout muted result-count", role: "status" }, count));
  if (tasks.length) out.push(taskList(tasks, { leaveWhenDone: false, label: "نتائج البحث" }));
  else out.push(emptyState(`لم نجد مهمة فيها «${q.trim()}».`));
  return out;
}

// ——— Task details and deletion ———

const taskDialog = {
  el: $("task-dialog"),
  title: $("task-dialog-title"),
  details: $("task-details"),
  error: $("task-error"),
  actions: $("task-actions"),
  confirm: $("task-confirm"),
  task: null,
  li: null,
};

// Light dismiss where `closedby` is not supported yet (Safari).
if (!("closedBy" in HTMLDialogElement.prototype)) {
  taskDialog.el.addEventListener("click", (event) => {
    if (event.target !== taskDialog.el) return;
    const r = taskDialog.el.getBoundingClientRect();
    const inside = r.top <= event.clientY && event.clientY <= r.bottom && r.left <= event.clientX && event.clientX <= r.right;
    if (!inside) taskDialog.el.close();
  });
}

function detail(term, ...value) {
  return [h("dt", { className: "caption muted" }, term), h("dd", { className: "body" }, ...value)];
}

function openTask(task, li) {
  taskDialog.task = task;
  taskDialog.li = li;
  taskDialog.title.textContent = task.title;
  taskDialog.error.textContent = "";
  taskDialog.actions.hidden = false;
  taskDialog.confirm.hidden = true;
  const rows = [];
  if (task.dueDate) {
    const word = relativeDay(task.dueDate, state.today);
    const full = dualDate(task.dueDate, { primary: primary(), today: state.today });
    rows.push(...detail("الموعد", word ? `${word}، ${full}` : `${weekdayName(task.dueDate)}، ${full}`));
  }
  const prayer = prayerPhrase(task.duePrayer, task.duePrayerOffset);
  if (prayer) rows.push(...detail("مع الصلاة", PrayerChip(prayer)));
  if (task.projectId) rows.push(...detail("المشروع", projectName(task.projectId) ?? "مشروع مشترك"));
  rows.push(...detail("الأولوية", PRIORITY_WORDS[task.priority] ?? PRIORITY_WORDS[0]));
  rows.push(...detail("الحالة", isOpen(task) ? "مفتوحة" : "منجزة"));
  if (task.notes) rows.push(...detail("الملاحظات", h("span", { className: "notes" }, task.notes)));
  taskDialog.details.replaceChildren(...rows);
  taskDialog.el.showModal();
}

$("task-close").addEventListener("click", () => taskDialog.el.close());
$("task-delete").addEventListener("click", () => {
  taskDialog.actions.hidden = true;
  taskDialog.confirm.hidden = false;
  $("task-delete-cancel").focus();
});
$("task-delete-cancel").addEventListener("click", () => {
  taskDialog.confirm.hidden = true;
  taskDialog.actions.hidden = false;
  $("task-delete").focus();
});
$("task-delete-confirm").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    await api.deleteTask(taskDialog.task.id);
    taskDialog.el.close();
    announce("حُذفت المهمة.");
    if (taskDialog.li) removeItem(taskDialog.li);
    refreshProjects();
  } catch (error) {
    if (error.status !== 401) taskDialog.error.textContent = errorText(error);
  } finally {
    button.disabled = false;
  }
});

// ——— Add a task ———

const addDialog = {
  el: $("add-dialog"),
  form: $("add-form"),
  title: $("add-title-input"),
  titleError: $("add-title-error"),
  date: $("add-date"),
  datePreview: $("add-date-preview"),
  prayer: $("add-prayer"),
  offset: $("prayer-offset"),
  minutes: $("add-minutes"),
  minutesError: $("add-minutes-error"),
  prayerPreview: $("prayer-preview"),
  project: $("add-project"),
  error: $("add-error"),
  submit: $("add-submit"),
};

function readMinutes() {
  const text = addDialog.minutes.value.trim();
  if (text === "") return 0;
  const n = parseDigits(text);
  return Number.isInteger(n) && n >= 0 && n <= 720 ? n : NaN;
}

function readOffset() {
  const minutes = readMinutes();
  const before = addDialog.form.elements.relation.value === "before";
  return before ? -minutes : minutes;
}

function updateDatePreview() {
  const value = addDialog.date.value;
  if (!isIsoDate(value)) {
    addDialog.datePreview.textContent = "بلا تاريخ";
    return;
  }
  const word = relativeDay(value, state.today);
  const full = dualDate(value, { primary: primary(), today: state.today });
  addDialog.datePreview.textContent = word ? `${word}، ${full}` : `${weekdayName(value)}، ${full}`;
}

function updatePrayerPreview() {
  const prayer = addDialog.prayer.value;
  addDialog.offset.hidden = !prayer;
  const offset = readOffset();
  addDialog.prayerPreview.textContent = prayer ? prayerPhrase(prayer, Number.isNaN(offset) ? 0 : offset) : "";
}

function fillProjects() {
  const writable = state.projects.filter((p) => p.kind === "project" && !p.archivedAt && (p.role === "owner" || p.role === "editor"));
  addDialog.project.replaceChildren(
    h("option", { value: "" }, "بلا مشروع"),
    ...writable.map((p) => h("option", { value: p.id }, p.name)),
  );
  const route = parseRoute();
  const preferred = route.name === "project" ? route.id : "";
  addDialog.project.value = writable.some((p) => p.id === preferred) ? preferred : "";
}

function openAdd() {
  addDialog.form.reset();
  addDialog.error.textContent = "";
  addDialog.titleError.textContent = "";
  addDialog.minutesError.textContent = "";
  addDialog.title.removeAttribute("aria-invalid");
  addDialog.minutes.removeAttribute("aria-invalid");
  const route = parseRoute();
  addDialog.date.value = route.name === "upcoming" ? addDays(state.today, 1) : route.name === "project" || route.name === "inbox" ? "" : state.today;
  fillProjects();
  updateDatePreview();
  updatePrayerPreview();
  addDialog.el.showModal();
  addDialog.title.focus();
}

els.addButton.addEventListener("click", openAdd);
$("add-cancel").addEventListener("click", () => addDialog.el.close());
addDialog.date.addEventListener("input", updateDatePreview);
addDialog.prayer.addEventListener("change", updatePrayerPreview);
addDialog.form.addEventListener("change", (event) => {
  if (event.target.name === "relation") updatePrayerPreview();
});
addDialog.minutes.addEventListener("input", () => {
  addDialog.minutesError.textContent = "";
  addDialog.minutes.removeAttribute("aria-invalid");
  updatePrayerPreview();
});
addDialog.title.addEventListener("input", () => {
  addDialog.titleError.textContent = "";
  addDialog.title.removeAttribute("aria-invalid");
});

function invalid(input, message, target) {
  target.textContent = message;
  input.setAttribute("aria-invalid", "true");
  input.focus();
}

addDialog.form.addEventListener("submit", async (event) => {
  event.preventDefault();
  addDialog.error.textContent = "";
  const title = addDialog.title.value.trim();
  if (!title) return invalid(addDialog.title, "اكتب عنوان المهمة.", addDialog.titleError);
  const prayer = addDialog.prayer.value || null;
  const offset = readOffset();
  if (prayer && Number.isNaN(offset)) return invalid(addDialog.minutes, "اكتب عدد الدقائق من ٠ إلى ٧٢٠.", addDialog.minutesError);

  const priority = Number(addDialog.form.elements.priority.value) || 0;
  const body = {
    title,
    dueDate: isIsoDate(addDialog.date.value) ? addDialog.date.value : null,
    duePrayer: prayer,
    duePrayerOffset: prayer ? offset : null,
    priority,
    projectId: addDialog.project.value || null,
  };
  addDialog.submit.disabled = true;
  try {
    await api.createTask(body);
    addDialog.el.close();
    announce("أُضيفت المهمة.");
    await refreshProjects();
    render({ focus: false });
  } catch (error) {
    if (error.status !== 401) addDialog.error.textContent = errorText(error);
  } finally {
    addDialog.submit.disabled = false;
  }
});

start();
