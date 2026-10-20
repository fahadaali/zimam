// زمام على الويب: sign in with Apple or Google, then the app's views over the REST API, in the frame
// MainView.swift lays out by width (shell.js): a tab bar on phones, the sidebar and an inspector for
// the open task on wide screens. Plain DOM and ES modules; views are chosen by the URL hash
// (#/today, #/projects/<id>, …; lib/routes.js), and ?task=<id> is the task open beside them.
import { api, apiBase, errorText, session, whenSignedOut } from "./lib/api.js";
import { ButtonLink, IconButton, ProjectCard, ScreenHeader, TaskRow, ViewToolbar, h, setRowDone, setRowSelected } from "./lib/components.js";
import { addDays, dayDiff, dayHeading, dualDate, dueChip, isIsoDate, localIsoDate, relativeDay, timeLabel, weekdayName } from "./lib/dates.js";
import {
  GOOGLE_CHANNEL,
  GOOGLE_MESSAGE_TYPE,
  GOOGLE_PENDING_KEY,
  GOOGLE_RESULT_KEY,
  googleAuthUrl,
  googleCallbackUrl,
  googleEnabled,
  googlePopupFeatures,
  googleState,
  googleStateMatches,
  isGoogleMessage,
} from "./lib/google.js";
import { icon } from "./lib/icons.js";
import { randomNonce, sha256Hex } from "./lib/nonce.js";
import { arabicNumber } from "./lib/numbers.js";
import { byManualOrder } from "./lib/order.js";
import { prayerPhrase } from "./lib/prayer.js";
import { createRealtime, realtimeUrl } from "./lib/realtime.js";
import { parseRoute as parseHash, routeKey, withTask } from "./lib/routes.js";
import { hasPendingImport, rememberPendingImport, viewImport } from "./import-view.js";
import { rememberPendingJoin, takePendingJoin, viewJoin } from "./invite-view.js";
import { groupByDay, isOpen, priorityKey, progressText, taskCount, todayList, topLevel } from "./lib/tasks.js";
// Features in their own modules: the assistant, the board, the calendar and sharing.
import { resetAddAssistant, setupAddAssistant, todaySummary } from "./assistant-view.js";
import { boardView, layoutOf, layoutToggle } from "./board-view.js";
import { calendarSelectedDay, viewCalendar } from "./calendar-view.js";
import { boardApi, remindersApi } from "./lib/feature-api.js";
import { nextOccurrence } from "./lib/recurrence.js";
import { newReminder } from "./lib/reminders.js";
import { canEdit } from "./lib/sharing.js";
import { openShare } from "./share-view.js";
// Start dates, the timeline (Gantt) and the priority matrix.
import { addStartField } from "./duration-view.js";
import { viewMatrix } from "./matrix-view.js";
import { projectTimeline, viewTimeline } from "./timeline-view.js";
// The frame and the open task.
import { createShell } from "./shell.js";
import { createTaskPane } from "./task-pane.js";
import { swipeToDelete } from "./swipe.js";
import { createPrayers } from "./prayer-view.js";
import { openSettings } from "./settings-view.js";

const APPLE_CLIENT_ID = "app.zimam.ios.web";
// Google OAuth web client ID (public). Empty hides the Google button. Keep it in the API's GOOGLE_CLIENT_IDS.
const GOOGLE_CLIENT_ID = "404741015373-ukucah8482ofiuvd9lb4cn4pgqvnfm75.apps.googleusercontent.com";
// From design/tokens.json through tokens.css; the numbers are fallbacks if it did not load.
const tokens = getComputedStyle(document.documentElement);
const LEAVE_AFTER = parseFloat(tokens.getPropertyValue("--duration-linger")) || 1000; // a completed task stays so it can be undone
const FADE = parseFloat(tokens.getPropertyValue("--duration-complete")) || 250;
const LIVE_DEBOUNCE = 800; // folds a burst of changes into one reload
const LIVE_RETRY = 2000; // while the person is in the middle of something

const $ = (id) => document.getElementById(id);
const els = {
  loading: $("loading"),
  signin: $("signin"),
  signinButton: $("signin-button"),
  signinError: $("signin-error"),
  googleButton: $("google-button"),
  signinInvite: $("signin-invite"),
  signinImport: $("signin-import"),
  shell: $("shell"),
  view: $("view"),
  main: $("main"),
  inspector: $("inspector"),
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
  /** When this tab last changed a task, so its own echo does not cut the leave animation short. */
  localChangeAt: 0,
  /** The tasks drawn as rows, by id, so the open task and its row are the same object. */
  taskIndex: new Map(),
  /** The view on screen (lib/routes.js routeKey), so a change of the open task alone keeps it. */
  shownKey: null,
};

/** The task open beside the list. `pushed`: opened on a phone, so «رجوع» is the browser's back. */
const selection = { pushed: false, scrollY: 0, focusBack: null };

const parseRoute = () => parseHash(location.hash);

const primary = () => state.me?.settings?.calendar ?? "hijri";
const projectName = (id) => state.projects.find((p) => p.id === id)?.name ?? null;
/** The viewer's role in a task's project; their own inbox is theirs. */
const roleFor = (task) => (task.projectId ? (state.projects.find((p) => p.id === task.projectId)?.role ?? null) : "owner");

/** What the feature modules (assistant, board, calendar, sharing) need from the app. */
function featureContext() {
  return {
    me: state.me,
    primary: primary(),
    today: state.today,
    projectName,
    announce,
    showError,
    errorText,
    taskItem,
    openTask: (task) => selectTask(task),
    canEditTask: (task) => canEdit(roleFor(task)),
    render: () => render({ focus: false }),
    refreshProjects: async () => {
      await refreshProjects();
      frame.refreshSidebar();
    },
    markLocalChange: () => (state.localChangeAt = Date.now()),
    onChanged: (task) => pane.refresh(task),
  };
}

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
  live.stop();
  els.loading.hidden = true;
  els.shell.hidden = true;
  els.signin.hidden = false;
  els.signinError.textContent = message;
  document.title = "تسجيل الدخول | زمام";
  // An invite opened before sign-in (#/join/<code>): say so, and keep it through Google's whole-tab sign-in.
  const route = parseRoute();
  els.signinInvite.hidden = route.name !== "join";
  if (route.name === "join") rememberPendingJoin(route.code);
  // Back from an import provider's page while signed out: sign in first; the import view then asks
  // which account receives the data, and the server refuses a flow another account started.
  els.signinImport.hidden = !(route.name === "import" && (rememberPendingImport() || hasPendingImport()));
  prepareNonce();
  prepareGoogle();
}

// ——— Sign in with Google ———

// Our own button opens Google's sign-in (lib/google.js); window.open must run inside the click,
// so the nonce for the next attempt is ready before it, as with Apple.
let googleNext = null;
/** The attempt waiting for Google's answer in a popup: { raw, state }. */
let googleAttempt = null;

async function prepareGoogle() {
  if (!googleEnabled(GOOGLE_CLIENT_ID)) return;
  els.googleButton.hidden = false;
  const raw = randomNonce();
  googleNext = { raw, hashed: await sha256Hex(raw), random: randomNonce(16) };
}

function setSigningIn(busy) {
  els.signinButton.disabled = busy;
  els.googleButton.disabled = busy;
}

els.googleButton.addEventListener("click", () => {
  els.signinError.textContent = "";
  const next = googleNext;
  if (!next) {
    els.signinError.textContent = "تعذّر بدء الدخول بحساب قوقل. حاول مرة أخرى.";
    return;
  }
  prepareGoogle();
  const authUrl = (mode) =>
    googleAuthUrl({
      clientId: GOOGLE_CLIENT_ID,
      redirectUri: googleCallbackUrl(location.origin),
      nonce: next.hashed,
      state: googleState(mode, next.random),
    });

  googleAttempt = { raw: next.raw, state: googleState("popup", next.random) };
  const popup = window.open(authUrl("popup"), "zimam-google", googlePopupFeatures());
  if (popup) return;

  // Popups blocked: the whole tab goes to Google and comes back to /app/ (takeGoogleRedirect).
  googleAttempt = null;
  try {
    sessionStorage.setItem(GOOGLE_PENDING_KEY, JSON.stringify({ raw: next.raw, state: googleState("redirect", next.random) }));
  } catch {
    els.signinError.textContent = "اسمح بالنوافذ المنبثقة لهذا الموقع، ثم حاول مرة أخرى.";
    return;
  }
  location.assign(authUrl("redirect"));
});

/** Google's answer from the popup, taken only for the attempt that opened it. */
function receiveGoogleAnswer(answer) {
  const attempt = googleAttempt;
  if (!attempt || !googleStateMatches(attempt.state, answer.state)) return;
  googleAttempt = null;
  completeGoogle(answer, attempt.raw);
}

if ("BroadcastChannel" in window) {
  new BroadcastChannel(GOOGLE_CHANNEL).addEventListener("message", (event) => {
    if (event.data?.type === GOOGLE_MESSAGE_TYPE) receiveGoogleAnswer(event.data);
  });
}
window.addEventListener("message", (event) => {
  if (isGoogleMessage(event.data, event.origin, location.origin)) receiveGoogleAnswer(event.data);
});

/** After a whole-tab sign-in: the answer google-callback.js left, if it matches the attempt. */
function takeGoogleRedirect() {
  let pending = null;
  let answer = null;
  try {
    pending = JSON.parse(sessionStorage.getItem(GOOGLE_PENDING_KEY) ?? "null");
    answer = JSON.parse(sessionStorage.getItem(GOOGLE_RESULT_KEY) ?? "null");
    sessionStorage.removeItem(GOOGLE_PENDING_KEY);
    sessionStorage.removeItem(GOOGLE_RESULT_KEY);
  } catch {
    return null;
  }
  if (!pending || !answer || !googleStateMatches(pending.state, answer.state)) return null;
  return { answer, raw: pending.raw };
}

async function completeGoogle(answer, raw) {
  els.signinError.textContent = "";
  if (answer.error) {
    // access_denied is the user closing Google's chooser; nothing to say.
    if (answer.error !== "access_denied") els.signinError.textContent = "تعذّر تسجيل الدخول بحساب قوقل. حاول مرة أخرى.";
    return;
  }
  setSigningIn(true);
  try {
    const { token } = await api.signInWithGoogle(answer.idToken, raw);
    session.set(token);
    await start();
  } catch (error) {
    els.signinError.textContent = errorText(error);
  } finally {
    setSigningIn(false);
  }
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
  // The API exchanges Apple's code with this same URI, so it must be in its APPLE_WEB_REDIRECT_URI
  // or APPLE_REDIRECT_URIS (and a Return URL of the Services ID).
  const redirectURI = `${location.origin}/app`;
  let result;
  try {
    apple.init({
      clientId: APPLE_CLIENT_ID,
      scope: "",
      redirectURI,
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
  setSigningIn(true);
  try {
    const code = result.authorization.code;
    const { token } = await api.signIn(idToken, attempt.raw, code ? { authorizationCode: code, redirectUri: redirectURI } : {});
    session.set(token);
    await start();
  } catch (error) {
    els.signinError.textContent = errorText(error);
  } finally {
    setSigningIn(false);
  }
});

whenSignedOut(() => showSignIn("انتهت الجلسة. سجّل الدخول مرة أخرى."));

els.signout.addEventListener("click", async () => {
  live.stop();
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
  pane.hide();
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
    els.view.replaceChildren(ScreenHeader("زمام"), emptyState("تعذّر تحميل حسابك."), retryButton());
    showError(error);
    return;
  }
  els.loading.hidden = true;
  els.signin.hidden = true;
  els.shell.hidden = false;
  // Back from a sign-in that lost the hash (Google's whole-tab flow): return to the invite.
  const pendingJoin = takePendingJoin();
  if (pendingJoin && parseRoute().name !== "join") history.replaceState(null, "", pendingJoin);
  // The same for an import provider's return, kept in this tab by rememberPendingImport().
  else if (hasPendingImport() && parseRoute().name !== "import") history.replaceState(null, "", `${location.pathname}${location.search}#/import`);
  frame.refreshSidebar();
  prayers.load();
  render({ focus: false });
  live.start();
}

/** «إعادة المحاولة» when the account could not be read (other than a signed-out session). */
function retryButton() {
  const button = h("button", { type: "button", className: "zm-btn zm-btn-secondary" }, "إعادة المحاولة");
  button.addEventListener("click", () => {
    clearError();
    start();
  });
  return button;
}

// ——— Realtime ———

// Changes from other devices, other members of a shared project, and Claude reload the view.
const live = createRealtime({
  getTicket: () => api.realtimeTicket(),
  urlFor: (ticket) => realtimeUrl(apiBase(), ticket),
  onChange: scheduleLiveRefresh,
});

let liveTimer;
function scheduleLiveRefresh() {
  clearTimeout(liveTimer);
  liveTimer = setTimeout(liveRefresh, LIVE_DEBOUNCE);
}

/** Whether a reload now would get in the way: a dialog, a drag, a task leaving its list, or typing. */
function busy() {
  if (document.querySelector("dialog[open]")) return true;
  if (document.body.classList.contains("is-dragging")) return true;
  if (Date.now() - state.localChangeAt < LEAVE_AFTER + FADE + 500) return true;
  if (pane.isBusy()) return true;
  const active = document.activeElement;
  return !!active && els.view.contains(active) && active.matches("input, select, textarea, :focus-visible");
}

async function liveRefresh() {
  if (els.shell.hidden) return;
  if (document.hidden) {
    document.addEventListener("visibilitychange", scheduleLiveRefresh, { once: true });
    return;
  }
  if (busy()) {
    liveTimer = setTimeout(liveRefresh, LIVE_RETRY);
    return;
  }
  await refreshProjects();
  frame.refreshSidebar();
  refreshOpenTask();
  // The import view follows its job itself; re-rendering would reset the form mid-way. The invite
  // view is a single request and a button, so it stays as it is too.
  if (parseRoute().name === "import" || parseRoute().name === "join") return;
  render({ focus: false });
}

/** The open task, read again after a change elsewhere: redrawn only if it changed, kept if gone. */
async function refreshOpenTask() {
  const id = pane.currentId();
  if (!id) return;
  try {
    const task = await api.task(id);
    if (pane.currentId() !== id) return;
    if (task.updatedAt !== state.taskIndex.get(id)?.updatedAt) {
      state.taskIndex.set(id, task);
      pane.refresh(task);
    }
  } catch (error) {
    if (error.status === 404 && pane.currentId() === id) pane.showMissing();
  }
}

// ——— «مزامنة الآن» ———

async function syncNow() {
  live.stop();
  await refreshProjects();
  await Promise.all([frame.refreshSidebar(), render({ focus: false }), refreshOpenTask()]);
  live.start();
  announce("تمت المزامنة.");
}

// ——— Routing ———

window.addEventListener("hashchange", () => {
  if (els.shell.hidden) return;
  const route = parseRoute();
  // Only the open task changed (a phone's task page, or back from it): keep the list as it is.
  if (routeKey(route) === state.shownKey) {
    syncTask(route.task ?? null, { focus: true });
    return;
  }
  render({ focus: true });
});

const VIEWS = {
  today: viewToday,
  upcoming: viewUpcoming,
  projects: viewProjects,
  project: viewProject,
  inbox: viewInbox,
  search: viewSearch,
  calendar: () => viewCalendar(featureContext()),
  timeline: () => withHeading(viewTimeline(featureContext())),
  matrix: () => withHeading(viewMatrix(featureContext())),
  import: () => viewImport({ primary: primary(), today: state.today, me: state.me, announce, onImported: featureContext().refreshProjects }),
  join: ({ code }) =>
    viewJoin({
      code,
      primary: primary(),
      today: state.today,
      announce,
      onJoined: async (projectId) => {
        await refreshProjects();
        frame.refreshSidebar();
        location.hash = `#/projects/${encodeURIComponent(projectId)}`;
      },
    }),
};

/** On phones the timeline and the matrix open from «المشاريع», so they get its back link. */
async function withHeading(content) {
  return [backToProjects(), ...(await content)];
}

async function render({ focus = false } = {}) {
  const id = ++state.renderId;
  state.today = localIsoDate();
  const route = parseRoute();
  frame.updateNav(route);
  clearError();
  let content;
  try {
    content = await VIEWS[route.name](route);
  } catch (error) {
    if (error.status === 401 || id !== state.renderId) return;
    content = [ScreenHeader("زمام"), emptyState("تعذّر تحميل هذه الصفحة.")];
    showError(error);
  }
  if (id !== state.renderId) return; // a newer navigation won
  state.shownKey = routeKey(route);
  els.view.replaceChildren(...content);
  const heading = els.view.querySelector("h1");
  document.title = `${heading?.textContent ?? "زمام"} | زمام`;
  if (focus && !route.task) heading?.focus();
  markSelected(pane.currentId());
  syncTask(route.task ?? null, { focus });
}

// ——— Prayer times and settings ———

const prayers = createPrayers({
  me: () => state.me,
  today: () => state.today,
  primary,
  saveSettings: (settings) => saveMe({ settings }),
  announce,
  errorText,
  onChange: () => {
    // The times arrived or changed: the chips and the line show clock times now.
    if (!busy()) render({ focus: false });
  },
});

/** Saves the name or settings (PATCH /v1/me) and redraws what depends on them. */
async function saveMe(fields) {
  state.me = await api.updateMe(fields);
  prayers.load();
  if (fields.settings && ("calendar" in fields.settings || "weekStart" in fields.settings)) render({ focus: false });
  return state.me;
}

$("settings-button").addEventListener("click", () =>
  openSettings({
    me: () => state.me,
    today: () => state.today,
    saveMe,
    openPrayers: () => prayers.openSheet(),
    sync: syncNow,
    signOut: () => els.signout.click(),
    deleteAccount: async () => {
      await api.deleteMe();
      live.stop();
      session.clear();
      state.me = null;
      state.projects = [];
      pane.hide();
      showSignIn("حُذف حسابك.");
    },
    announce,
    errorText,
  }),
);

// ——— The open task ———

const frame = createShell({
  state,
  announce,
  showError,
  refreshProjects,
  render: () => render({ focus: false }),
  onLayout: () => markSelected(pane.currentId()),
  moveTask,
  sync: syncNow,
});

const pane = createTaskPane({
  primary,
  today: () => state.today,
  projectName,
  roleFor,
  canEdit: (task) => canEdit(roleFor(task)),
  writableProjects,
  save: saveTask,
  markLocalChange: () => (state.localChangeAt = Date.now()),
  featureContext,
  toggle: (task) => toggleTask(task),
  remove: removeTask,
  close: closeTask,
  announce,
  errorText,
  api,
});

/** A row asks to open its task: its own page on a phone, the inspector beside the list on wide screens. */
function selectTask(task) {
  state.taskIndex.set(task.id, state.taskIndex.get(task.id) ?? task);
  if (frame.layout() === "compact") {
    selection.pushed = true;
    selection.scrollY = window.scrollY;
    location.hash = withTask(location.hash, task.id); // hashchange → syncTask
    return;
  }
  history.replaceState(null, "", withTask(location.hash, task.id));
  syncTask(task.id, { focus: true });
}

/** Shows the task named in the URL, or closes the pane when there is none. */
async function syncTask(id, { focus = false } = {}) {
  if (!id) {
    if (!els.inspector.hidden) hidePane();
    return;
  }
  if (pane.isShown(id)) return;
  let task = state.taskIndex.get(id);
  if (!task) {
    try {
      task = await api.task(id);
      state.taskIndex.set(id, task);
    } catch (error) {
      if (parseRoute().task !== id) return;
      if (error.status === 404 || error.status === 403) pane.showMissing();
      else if (error.status !== 401) showError(error);
      return;
    }
    if (parseRoute().task !== id) return; // another task was chosen meanwhile
  }
  selection.focusBack = id;
  pane.show(task, { focus });
  markSelected(id);
  if (frame.layout() === "compact") window.scrollTo(0, 0);
}

function hidePane() {
  pane.hide();
  markSelected(null);
  if (frame.layout() === "compact") window.scrollTo(0, selection.scrollY);
  const back = selection.focusBack;
  selection.focusBack = null;
  if (!back) return;
  const row = findItem(back);
  (row?.querySelector(".zm-task-open") ?? els.view.querySelector("h1"))?.focus({ preventScroll: true });
}

/** «رجوع» or «إغلاق»: back to the list, as the app pops the task or closes its inspector. */
function closeTask({ restoreFocus = false } = {}) {
  if (!restoreFocus) selection.focusBack = null;
  if (selection.pushed) {
    selection.pushed = false;
    history.back(); // hashchange → syncTask(null)
    return;
  }
  history.replaceState(null, "", withTask(location.hash, null));
  hidePane();
}

function findItem(taskId) {
  return [...els.view.querySelectorAll(".task-item[data-task-id]")].find((li) => li.dataset.taskId === taskId) ?? null;
}

function markSelected(taskId) {
  for (const li of els.view.querySelectorAll(".task-item[data-task-id]")) {
    const row = li.querySelector(".zm-task");
    if (row) setRowSelected(row, li.dataset.taskId === taskId);
  }
}

/** Projects a task can be added to or moved into: the person's own and those they edit. */
function writableProjects() {
  return state.projects.filter((p) => p.kind !== "folder" && !p.archivedAt && canEdit(p.role ?? "owner"));
}

let viewRefreshTimer;
/** Redraws the list a moment after an edit in the pane, so a burst of edits redraws it once. */
function refreshViewSoon() {
  clearTimeout(viewRefreshTimer);
  viewRefreshTimer = setTimeout(() => {
    render({ focus: false });
    frame.refreshSidebar();
  }, 400);
}

/** A field changed in the open task's editor: saved, then the pane and the list follow. */
async function saveTask(task, fields) {
  state.localChangeAt = Date.now();
  const saved = await api.patchTask(task.id, fields);
  for (const copy of new Set([task, state.taskIndex.get(task.id), pane.currentTask(task.id)].filter(Boolean))) Object.assign(copy, saved);
  pane.refresh(saved);
  if ("projectId" in fields) refreshProjects();
  refreshViewSoon();
  return saved;
}

/** After «حذف المهمة»: the pane closes and the task's row leaves its list. */
function removeTask(task) {
  state.taskIndex.delete(task.id);
  selection.focusBack = null;
  closeTask();
  const li = findItem(task.id);
  if (li) removeItem(li);
  else render({ focus: false }); // drawn as a bar (calendar, timeline): redraw without it
  refreshProjects().then(() => frame.refreshSidebar());
}

/** A task dropped on «صندوق المهام», a project or a section in the sidebar. */
async function moveTask(taskId, { projectId, sectionId, label }) {
  const known = state.taskIndex.get(taskId);
  if (known?.parentId) {
    showError("المهمة الفرعية تبقى مع مهمتها. انقل المهمة الأصل.");
    return;
  }
  if (known && (known.projectId ?? null) === projectId && (known.sectionId ?? null) === sectionId) return;
  clearError();
  state.localChangeAt = Date.now();
  try {
    const saved = await boardApi.patchTask(taskId, { projectId, sectionId });
    if (known) Object.assign(known, saved);
    announce(`نُقلت «${saved.title}» إلى ${label}.`);
    pane.refresh(saved);
    await refreshProjects();
    frame.refreshSidebar();
    render({ focus: false });
  } catch (error) {
    if (error.status !== 401) showError(error);
  }
}

// ——— Shared pieces ———

function emptyState(text) {
  return h("p", { className: "callout empty" }, text);
}

/** «المشاريع» above a project, the timeline or the matrix on phones (the app pushes them from there). */
function backToProjects() {
  return h(
    "nav",
    { className: "breadcrumb compact-only", "aria-label": "المسار" },
    ButtonLink({ variant: "quiet", href: "#/projects", className: "back-link" }, icon("chevron-back", { size: "sm" }), "المشاريع"),
  );
}

const TASK_TYPE = "application/x-zimam-task";

/**
 * A list of TaskRows. `showDate` adds the due-date chip; `leaveWhenDone` removes a task a second
 * after it is completed (open-task lists), so the circle can be tapped again to undo.
 */
function taskList(tasks, { showDate = true, showProject = true, leaveWhenDone = true, label } = {}) {
  const list = h("ul", { className: "task-list", role: "list", "aria-label": label });
  for (const task of tasks) list.append(taskItem(task, { showDate, showProject, leaveWhenDone, swipe: true }));
  return list;
}

function taskItem(task, options) {
  const li = h("li", { className: "task-item", dataset: { taskId: task.id } });
  state.taskIndex.set(task.id, task);
  const row = TaskRow({
    title: task.title,
    note: task.notes ? task.notes.split("\n")[0] : null,
    done: task.status === "done",
    priority: priorityKey(task.priority),
    date: options.showDate && task.dueDate ? dueChip(task.dueDate, { today: state.today, primary: primary() }) : null,
    time: task.dueDate && !task.duePrayer ? timeLabel(task.dueTime) : null,
    prayer: prayers.chipFor(task),
    project: options.showProject && task.projectId ? projectName(task.projectId) : null,
    selected: pane.currentId() === task.id,
    onToggle: () => toggleTask(task, li),
    onOpen: () => selectTask(task),
  });
  li.task = task;
  li.row = row;
  li.leaveWhenDone = options.leaveWhenDone;
  li.append(row);
  // Any top-level task can be dragged to «صندوق المهام» or a project in the sidebar; the board,
  // calendar and matrix add their own drops on top of this.
  if (!task.parentId && canEdit(roleFor(task))) {
    li.draggable = true;
    li.addEventListener("dragstart", (event) => {
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData(TASK_TYPE, task.id);
      if (!event.dataTransfer.getData("text/plain")) event.dataTransfer.setData("text/plain", task.title);
      document.body.classList.add("is-dragging");
    });
    li.addEventListener("dragend", () => document.body.classList.remove("is-dragging"));
  }
  // In lists on phones, a swipe toward the inline end shows «حذف» (swipe.js).
  if (options.swipe && canEdit(roleFor(task))) {
    swipeToDelete(li, { isCompact: () => frame.layout() === "compact", onDelete: () => deleteFromRow(task, li), label: task.title });
  }
  return li;
}

/** «حذف» on a swiped row: deleted at once, as the app's swipe action does. */
async function deleteFromRow(task, li) {
  clearError();
  try {
    state.localChangeAt = Date.now();
    await api.deleteTask(task.id);
    announce("حُذفت المهمة.");
    state.taskIndex.delete(task.id);
    if (pane.currentId() === task.id) closeTask();
    removeItem(li);
    refreshProjects().then(() => frame.refreshSidebar());
  } catch (error) {
    if (error.status !== 401) showError(error);
  }
}

/** Completes or reopens a task, from its circle or the pane's «إنجاز»; the row and the pane follow. */
async function toggleTask(task, li = findItem(task.id)) {
  const done = isOpen(task);
  const previous = task.status;
  const copies = new Set([task, li?.task, state.taskIndex.get(task.id), pane.currentTask(task.id)].filter(Boolean));
  const show = (status) => {
    for (const copy of copies) copy.status = status;
    if (li?.row) setRowDone(li.row, status === "done", task.title);
    pane.setToggle(task);
  };
  show(done ? "done" : "todo");
  if (li) {
    clearTimeout(li.leaveTimer);
    li.classList.remove("is-leaving");
  }
  clearError();
  state.localChangeAt = Date.now();

  const call = done ? api.completeTask(task.id) : api.reopenTask(task.id);
  if (done && li?.leaveWhenDone) li.leaveTimer = setTimeout(() => leave(li, li.task), LEAVE_AFTER);
  try {
    const saved = await call;
    for (const copy of copies) Object.assign(copy, saved);
    pane.refresh(saved);
    announce(done ? "أُنجزت المهمة." : "أُعيدت المهمة إلى المفتوحة.");
    if (done && saved.recurrence) addNextOccurrence(saved);
    refreshProjects().then(() => frame.refreshSidebar());
  } catch (error) {
    if (li) {
      clearTimeout(li.leaveTimer);
      li.classList.remove("is-leaving");
    }
    show(previous);
    if (error.status !== 401) showError(error);
  }
}

/**
 * Completing a repeating task adds its next occurrence as a new task, with the same reminders,
 * as Store.addNextOccurrence does; the completed one stays done. An open copy on that day with
 * the same title is the next occurrence already (added by another device).
 */
async function addNextOccurrence(task) {
  const next = nextOccurrence(task.recurrence, task.dueDate ?? state.today, state.today);
  if (!next) return;
  try {
    const { tasks } = await api.tasks({ status: "open", dueFrom: next.day, dueTo: next.day, projectId: task.projectId ?? "inbox" });
    if (tasks.some((t) => t.id !== task.id && t.title === task.title && (t.parentId ?? null) === (task.parentId ?? null))) return;
    const span = task.startDate && task.dueDate ? dayDiff(task.startDate, task.dueDate) : 0;
    const copy = await api.createTask({
      title: task.title,
      notes: task.notes,
      tags: task.tags,
      priority: task.priority,
      projectId: task.projectId,
      sectionId: task.sectionId,
      parentId: task.parentId,
      dueDate: next.day,
      ...(span > 0 ? { startDate: addDays(next.day, -span) } : {}),
      dueTime: task.dueTime,
      duePrayer: task.duePrayer,
      duePrayerOffset: task.duePrayerOffset,
      recurrence: next.recurrence,
      assigneeId: task.assigneeId,
      sortOrder: task.sortOrder,
    });
    const { reminders } = await remindersApi.list(task.id);
    const shift = task.dueDate ? dayDiff(task.dueDate, next.day) : 0;
    const copies = reminders
      .filter((r) => r.kind !== "time" || shiftIso(r.at, shift))
      .map((r) => ({ op: "upsert", entity: "reminder", data: newReminder(copy.id, { kind: r.kind, at: r.kind === "time" ? shiftIso(r.at, shift) : r.at, prayer: r.prayer, offsetMinutes: r.offsetMinutes, location: r.location }) }));
    if (copies.length) await remindersApi.save(copies);
    announce(`أُضيف موعدها القادم: ${dateLabelFor(next.day)}.`);
    refreshViewSoon();
  } catch (error) {
    if (error.status !== 401) showError(error);
  }
}

/** An ISO time moved by whole days, its clock time and offset kept; null if it cannot be read. */
function shiftIso(at, days) {
  const m = /^(\d{4}-\d{2}-\d{2})(T.*)$/.exec(at ?? "");
  return m ? `${addDays(m[1], days)}${m[2]}` : null;
}

const dateLabelFor = (iso) => relativeDay(iso, state.today) ?? dualDate(iso, { primary: primary(), today: state.today });

function leave(li, task) {
  if (isOpen(task) || !li.isConnected) return;
  li.classList.add("is-leaving");
  // A fade, not a movement, so it stays with Reduce Motion as in the app.
  setTimeout(() => removeItem(li), FADE);
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
  const list = todayList(tasks, today);
  const out = [
    ViewToolbar(frame.accountButton()),
    ScreenHeader("اليوم", dualDate(today, { primary: primary(), today })),
    prayers.nextLine(),
    todaySummary(featureContext()),
  ];
  out.push(list.length ? taskList(list, { label: "مهام اليوم" }) : emptyState("لا مهام اليوم. يومك لك."));
  return out;
}

async function viewUpcoming() {
  const tomorrow = addDays(state.today, 1);
  const { tasks } = await api.tasks({ status: "open", dueFrom: tomorrow });
  const out = [ScreenHeader("القادم")];
  const groups = groupByDay(topLevel(tasks));
  if (groups.length === 0) {
    out.push(emptyState("لا مهام قادمة."));
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
  const projects = state.projects.filter((p) => p.kind !== "folder" && !p.archivedAt);
  const newProject = IconButton({ icon: "plus", label: "مشروع جديد", "aria-haspopup": "dialog", onclick: () => frame.openNewProject() });
  const join = IconButton({ icon: "user-plus", label: "الانضمام بدعوة", "aria-haspopup": "dialog", onclick: () => frame.openJoin() });
  const out = [ViewToolbar(join, newProject), ScreenHeader("المشاريع")];
  // On phones the timeline and the matrix open from here (ProjectsView.swift); wide screens have them in the sidebar.
  out.push(
    h("ul", { className: "overview-rows compact-only", role: "list" },
      overviewRow("#/timeline", "timeline", "المخطط الزمني"),
      overviewRow("#/matrix", "matrix", "المصفوفة"),
      overviewRow("#/inbox", "inbox", "صندوق المهام")),
  );
  if (projects.length === 0) out.push(emptyState("لا مشاريع بعد."));
  else {
    const grid = h("ul", { className: "project-grid", role: "list" });
    for (const p of projects) {
      grid.append(h("li", null, ProjectCard({ name: p.name, done: p.doneCount ?? 0, total: p.taskCount ?? 0, href: `#/projects/${encodeURIComponent(p.id)}` })));
    }
    out.push(grid);
  }
  return out;
}

function overviewRow(href, iconName, label) {
  return h("li", null, h("a", { className: "overview-row body", href }, icon(iconName), h("span", { className: "sidebar-label" }, label), icon("chevron-forward", { size: "sm" })));
}

/** Open tasks by section, as ProjectDetailView's list: those with no section first, then each section. */
function sectionGroups(open, sections) {
  const known = new Set(sections.map((s) => s.id));
  const groups = [{ section: null, tasks: open.filter((t) => !t.sectionId || !known.has(t.sectionId)) }];
  for (const section of [...sections].sort(byManualOrder)) groups.push({ section, tasks: open.filter((t) => t.sectionId === section.id) });
  return groups.filter((g) => g.tasks.length);
}

async function projectTasksView({ title, subtitle, projectId, project = null, sectionId = null, empty }) {
  const [{ tasks }, detail] = await Promise.all([api.tasks({ projectId }), project ? boardApi.project(project.id) : null]);
  const sections = detail?.sections ?? [];
  const top = topLevel(tasks);
  const out = [backToProjects()];
  if (project && !sectionId && layoutOf(project) === "kanban") {
    out.push(ScreenHeader(title, subtitle, projectTools(project)));
    out.push(boardView({ project: { ...project, role: detail.role ?? project.role }, sections, tasks: top }, featureContext()));
    return out;
  }
  if (project && !sectionId && layoutOf(project) === "timeline") {
    out.push(ScreenHeader(title, subtitle, projectTools(project)));
    out.push(projectTimeline({ project, sections, tasks: top }, featureContext()));
    return out;
  }
  const scoped = sectionId ? top.filter((t) => t.sectionId === sectionId) : top;
  const open = scoped.filter(isOpen).sort(byManualOrder);
  const done = scoped.filter((t) => !isOpen(t));
  out.push(ScreenHeader(title, subtitle, project && !sectionId ? projectTools(project) : null));
  if (open.length === 0) out.push(emptyState(empty));
  for (const { section, tasks: groupTasks } of sectionId ? [{ section: null, tasks: open }] : sectionGroups(open, sections)) {
    if (!section) {
      out.push(taskList(groupTasks, { showProject: false, label: "المهام المفتوحة" }));
      continue;
    }
    const titleId = `section-${section.id}`;
    out.push(
      h("section", { className: "list-section", "aria-labelledby": titleId },
        h("h2", { className: "headline section-title", id: titleId }, section.name),
        taskList(groupTasks, { showProject: false, label: section.name })),
    );
  }
  if (done.length) {
    out.push(
      h("details", { className: "done-section" },
        h("summary", { className: "headline muted" }, "المنجزة ", h("span", { className: "caption muted" }, taskCount(done.length))),
        taskList(done, { showProject: false, leaveWhenDone: false, label: "المهام المنجزة" })),
    );
  }
  return out;
}

async function viewProject({ id, section }) {
  let project = state.projects.find((p) => p.id === id);
  if (!project) project = await api.project(id);
  if (section) {
    const detail = await boardApi.project(id);
    const found = (detail.sections ?? []).find((s) => s.id === section);
    return projectTasksView({ title: found?.name ?? "قسم", subtitle: project.name, projectId: id, project, sectionId: section, empty: "لا مهام مفتوحة في هذا القسم." });
  }
  const counts = project.taskCount != null ? progressText(project.doneCount ?? 0, project.taskCount) : null;
  return projectTasksView({ title: project.name, subtitle: counts, projectId: id, project, empty: "لا مهام مفتوحة في هذا المشروع." });
}

/** List, board or timeline, and «مشاركة», under a project's title. */
function projectTools(project) {
  const share = h("button", { type: "button", className: "zm-btn zm-btn-secondary", "aria-haspopup": "dialog" }, icon("users", { size: "sm" }), "مشاركة");
  share.addEventListener("click", () =>
    openShare(project, {
      ...featureContext(),
      onLeft: () => {
        location.hash = "#/projects";
      },
    }),
  );
  return h("div", { className: "project-tools" }, layoutToggle(project, featureContext()), share);
}

async function viewInbox() {
  return projectTasksView({ title: "صندوق المهام", subtitle: "المهام التي لا مشروع لها.", projectId: "inbox", empty: "لا مهام بلا مشروع." });
}

async function viewSearch({ q }) {
  const input = h("input", {
    className: "input body",
    id: "search-input",
    name: "q",
    type: "search",
    value: q,
    placeholder: "ابحث في المهام",
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
    h("label", { className: "visually-hidden", for: "search-input" }, "ابحث في المهام"),
    h("div", { className: "search-row" }, h("span", { className: "search-icon", "aria-hidden": "true" }, icon("search")), input),
  );
  const out = [ScreenHeader("البحث"), h("search", null, form)];
  if (!q.trim()) {
    out.push(emptyState("ابحث في عناوين المهام وملاحظاتها ووسومها."));
    return out;
  }
  const { tasks } = await api.tasks({ q: q.trim() });
  const found = topLevel(tasks);
  const count = found.length === 0 ? "لا نتائج." : found.length === 1 ? "نتيجة واحدة" : `${arabicNumber(found.length)} نتائج`;
  out.push(h("p", { className: "caption muted result-count", role: "status" }, count));
  if (found.length) out.push(taskList(found, { leaveWhenDone: false, label: "نتائج البحث" }));
  return out;
}

// ⌘F / Ctrl+F: «بحث», as on the Mac. The browser's own find stays on the search screen itself.
document.addEventListener("keydown", (event) => {
  if (event.key.toLowerCase() !== "f" || !(event.metaKey || event.ctrlKey) || event.shiftKey || event.altKey) return;
  if (els.shell.hidden || document.querySelector("dialog[open]")) return;
  if (parseRoute().name === "search") {
    const input = $("search-input");
    if (document.activeElement === input) return;
    event.preventDefault();
    input?.focus();
    return;
  }
  event.preventDefault();
  location.hash = "#/search";
});

// ——— Add a task ———

// «مهمة جديدة» as AddTaskView.swift: the title (and «اقتراح بالمساعد», assistant-view.js), notes and
// tags; «الموعد»: none, today, tomorrow or another date, with an optional start date; «الوقت»: all
// day, a clock time or around a prayer; the priority and the project. A task with a time gets an
// «عند الموعد» reminder, as ensureAtTimeReminder does.
const addDialog = {
  el: $("add-dialog"),
  form: $("add-form"),
  title: $("add-title-input"),
  titleError: $("add-title-error"),
  notes: $("add-notes"),
  tags: $("add-tags"),
  date: $("add-date"),
  dateRow: $("add-date-row"),
  datePreview: $("add-date-preview"),
  startRow: $("add-start-row"),
  timeRow: $("add-time-row"),
  time: $("add-time"),
  timeNote: $("add-time-note"),
  prayer: $("add-prayer"),
  offsetBox: $("prayer-offset"),
  offset: $("add-offset"),
  prayerPreview: $("prayer-preview"),
  project: $("add-project"),
  error: $("add-error"),
  submit: $("add-submit"),
};

/** «تاريخ البداية» under the date (duration-view.js). */
const addStart = addStartField(
  { start: $("add-start"), due: $("add-date"), preview: $("add-start-preview"), error: $("add-start-error") },
  () => ({ primary: primary(), today: state.today }),
);

const radio = (name) => addDialog.form.elements[name];

/** Which «الموعد» choice a date is: none, today, tomorrow or another date. */
function dueChoice(iso) {
  if (!isIsoDate(iso)) return "none";
  if (iso === state.today) return "today";
  if (iso === addDays(state.today, 1)) return "tomorrow";
  return "other";
}

/** The rows that follow the choices: the date field, the start date, the clock or the prayer. */
function updateAddForm() {
  const value = addDialog.date.value;
  const choice = radio("due").value;
  addDialog.dateRow.hidden = choice !== "other";
  addDialog.startRow.hidden = !isIsoDate(value);
  if (!isIsoDate(value)) addDialog.datePreview.textContent = "بلا موعد";
  else {
    const word = relativeDay(value, state.today);
    const full = dualDate(value, { primary: primary(), today: state.today });
    addDialog.datePreview.textContent = word ? `${word}، ${full}` : `${weekdayName(value)}، ${full}`;
  }
  const mode = radio("timeMode").value;
  addDialog.timeRow.hidden = mode !== "clock";
  addDialog.time.disabled = !isIsoDate(value);
  addDialog.timeNote.hidden = isIsoDate(value);
  addDialog.offsetBox.hidden = mode !== "prayer";
  const offset = Number(addDialog.offset.value) || 0;
  $("add-offset-minus").disabled = offset <= -120;
  $("add-offset-plus").disabled = offset >= 120;
  addDialog.prayerPreview.replaceChildren(icon("moon-star", { size: "xs" }), prayerPhrase(addDialog.prayer.value || "asr", offset));
}

function setDue(choice) {
  radio("due").value = choice;
  if (choice === "none") addDialog.date.value = "";
  else if (choice === "today") addDialog.date.value = state.today;
  else if (choice === "tomorrow") addDialog.date.value = addDays(state.today, 1);
  else if (!isIsoDate(addDialog.date.value)) addDialog.date.value = addDays(state.today, 2);
  updateAddForm();
}

function fillProjects() {
  const writable = writableProjects();
  addDialog.project.replaceChildren(
    h("option", { value: "" }, "صندوق المهام"),
    ...writable.map((p) => h("option", { value: p.id }, p.name)),
  );
  const route = parseRoute();
  const preferred = route.name === "project" ? route.id : "";
  addDialog.project.value = writable.some((p) => p.id === preferred) ? preferred : "";
}

/** Where a new task lands by default, as MainView.swift decides it: today, tomorrow, the shown day, or none. */
function defaultDue(route) {
  if (route.name === "today") return state.today;
  if (route.name === "upcoming") return addDays(state.today, 1);
  if (route.name === "calendar" && isIsoDate(calendarSelectedDay())) return calendarSelectedDay();
  return "";
}

function openAdd() {
  addDialog.form.reset();
  addDialog.error.textContent = "";
  addDialog.titleError.textContent = "";
  addDialog.title.removeAttribute("aria-invalid");
  addDialog.offset.value = "0";
  addDialog.date.value = defaultDue(parseRoute());
  radio("due").value = dueChoice(addDialog.date.value);
  resetAddAssistant();
  addStart.reset();
  fillProjects();
  updateAddForm();
  addDialog.el.showModal();
  addDialog.title.focus();
}

els.addButton.addEventListener("click", openAdd);
$("add-cancel").addEventListener("click", () => addDialog.el.close());
addDialog.form.addEventListener("change", (event) => {
  if (event.target.name === "due") setDue(event.target.value);
  else updateAddForm();
});
addDialog.date.addEventListener("input", () => {
  radio("due").value = dueChoice(addDialog.date.value) === "none" ? "none" : "other";
  updateAddForm();
});
for (const [id, step] of [["add-offset-minus", -5], ["add-offset-plus", 5]]) {
  $(id).addEventListener("click", () => {
    addDialog.offset.value = String(Math.max(-120, Math.min(120, (Number(addDialog.offset.value) || 0) + step)));
    updateAddForm();
  });
}
addDialog.title.addEventListener("input", () => {
  addDialog.titleError.textContent = "";
  addDialog.title.removeAttribute("aria-invalid");
});

// «تعديل» on the assistant's suggestion: its fields into the form (assistant-view.js).
addDialog.form.addEventListener("zimam:fill", ({ detail: task }) => {
  addDialog.title.value = task.title ?? "";
  addDialog.notes.value = task.notes ?? "";
  addDialog.tags.value = (task.tags ?? []).join("، ");
  addDialog.date.value = task.dueDate ?? "";
  radio("due").value = dueChoice(addDialog.date.value);
  if (task.duePrayer) {
    radio("timeMode").value = "prayer";
    addDialog.prayer.value = task.duePrayer;
    addDialog.offset.value = String(task.duePrayerOffset ?? 0);
  } else if (task.dueTime && task.dueDate) {
    radio("timeMode").value = "clock";
    addDialog.time.value = task.dueTime;
  } else radio("timeMode").value = "allDay";
  radio("priority").value = String(task.priority ?? 0);
  if (task.projectId && [...addDialog.project.options].some((o) => o.value === task.projectId)) addDialog.project.value = task.projectId;
  updateAddForm();
});

// ⌘N is the browser's new window; Alt+N (Option+N) adds a task, as «مهمة جديدة» does on the Mac.
document.addEventListener("keydown", (event) => {
  if (event.code !== "KeyN" || !event.altKey || event.metaKey || event.ctrlKey) return;
  if (els.shell.hidden || document.querySelector("dialog[open]")) return;
  event.preventDefault();
  openAdd();
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
  if (!addStart.check()) return;

  const dueDate = isIsoDate(addDialog.date.value) ? addDialog.date.value : null;
  const mode = radio("timeMode").value;
  const dueTime = mode === "clock" && dueDate && /^\d{2}:\d{2}$/.test(addDialog.time.value) ? addDialog.time.value : null;
  const prayer = mode === "prayer" ? addDialog.prayer.value || "asr" : null;
  const route = parseRoute();
  const projectId = addDialog.project.value || null;
  const body = {
    title,
    notes: addDialog.notes.value.trim() ? addDialog.notes.value : null,
    tags: [...new Set(addDialog.tags.value.split(/[,،]/).map((t) => t.trim()).filter(Boolean))].slice(0, 30),
    dueDate,
    ...addStart.fields(), // `startDate` only when one is set
    dueTime,
    duePrayer: prayer,
    duePrayerOffset: prayer ? Number(addDialog.offset.value) || 0 : null,
    priority: Number(radio("priority").value) || 0,
    projectId,
    // Added from a section's list: into that section.
    sectionId: route.name === "project" && route.section && projectId === route.id ? route.section : null,
  };
  addDialog.submit.disabled = true;
  try {
    state.localChangeAt = Date.now();
    const task = await api.createTask(body);
    // A task with a time reminds at it, as the app adds «عند الموعد» (ensureAtTimeReminder).
    if (dueTime || prayer) await remindersApi.add(newReminder(task.id, { kind: "relative", offsetMinutes: 0 })).catch(() => {});
    addDialog.el.close();
    announce("أُضيفت المهمة.");
    await refreshProjects();
    frame.refreshSidebar();
    render({ focus: false });
  } catch (error) {
    if (error.status !== 401) addDialog.error.textContent = errorText(error);
  } finally {
    addDialog.submit.disabled = false;
  }
});

setupAddAssistant(featureContext);

// Back from Google in this tab (popups were blocked): finish that sign-in first.
const googleRedirect = takeGoogleRedirect();
if (googleRedirect && !session.get()) {
  showSignIn();
  completeGoogle(googleRedirect.answer, googleRedirect.raw);
} else {
  start();
}
