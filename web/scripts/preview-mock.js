// The API for the live preview (scripts/preview.mjs): the web app runs in an iPhone frame with no
// server, and this module answers its requests from the demo data (demo-data.js, a copy of
// scripts/demo-data.mjs), keeping what the viewer changes until the page reloads: a task added,
// completed, edited or deleted, a project, a section, a reminder, a comment, a setting.
// It is loaded before main.js, so the app's code already sees the clock and fetch set here.
import { NOW, answer, tasks } from "./demo-data.js";

const API = "https://api.zimam.work";

// The clock starts at the demo's moment (Wednesday 9:41 in Riyadh) and runs from there, so the
// demo days stay right and the prayer countdown moves.
const shift = Date.parse(NOW) - Date.now();
const RealDate = Date;
globalThis.Date = class extends RealDate {
  constructor(...args) {
    super(...(args.length ? args : [RealDate.now() + shift]));
  }
  static now() {
    return RealDate.now() + shift;
  }
};

// Signed in from the start, and nothing kept between visits: storage in memory only, so the
// preview works where the page's storage is blocked and always opens on the same demo.
function memoryStorage() {
  const items = new Map();
  return {
    get length() {
      return items.size;
    },
    key: (i) => [...items.keys()][i] ?? null,
    getItem: (k) => (items.has(String(k)) ? items.get(String(k)) : null),
    setItem: (k, v) => void items.set(String(k), String(v)),
    removeItem: (k) => void items.delete(String(k)),
    clear: () => items.clear(),
  };
}
for (const name of ["localStorage", "sessionStorage"]) {
  try {
    Object.defineProperty(globalThis, name, { value: memoryStorage(), configurable: true });
  } catch {
    /* the browser's own storage, then */
  }
}
try {
  localStorage.setItem("zimam.session", "demo");
} catch {
  /* api.js keeps a token in memory only when it sets one itself; the app then opens on sign-in */
}

// Live updates: a socket that never opens, so the app neither retries nor reaches the network.
globalThis.WebSocket = class {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  readyState = 0;
  addEventListener() {}
  removeEventListener() {}
  send() {}
  close() {
    this.readyState = 3;
  }
};

// Links out of the app («عن زمام»، الخصوصية، الشروط) lead to pages the preview does not carry:
// they stay where they are instead of loading a blank page into the phone.
document.addEventListener(
  "click",
  (event) => {
    const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
    if (!link || link.getAttribute("href").startsWith("#")) return;
    const to = new URL(link.href, location.href);
    if (to.origin === location.origin && to.pathname === location.pathname) return;
    event.preventDefault();
  },
  true,
);

// ——— The state the viewer changes ———

const now = () => Date.now();
let serial = 0;
const newId = (prefix) => `${prefix}-preview-${++serial}`;
const read = (path) => answer("GET", API + path).body;

const me = read("/v1/me");
const projects = read("/v1/projects").projects;
const reminders = new Map(); // taskId → reminders, read from the demo the first time
const comments = new Map(); // taskId → comments

const taskById = (id) => tasks.find((t) => t.id === id);
const projectById = (id) => projects.find((p) => p.id === id);

/** A project as GET /v1/projects answers it, its counts taken from the tasks as they are now. */
function projectOut(p) {
  const own = tasks.filter((t) => t.projectId === p.id && !t.parentId);
  return { ...p, taskCount: own.length, doneCount: own.filter((t) => t.status === "done").length, sections: [...p.sections].sort((a, b) => a.sortOrder - b.sortOrder) };
}

function remindersOf(taskId) {
  if (!reminders.has(taskId)) reminders.set(taskId, read(`/v1/tasks/${taskId}/reminders`).reminders ?? []);
  return reminders.get(taskId);
}

function newTask(fields) {
  const top = tasks.reduce((n, t) => Math.max(n, t.sortOrder ?? 0), 0);
  const task = {
    id: newId("t"),
    ownerId: me.id,
    projectId: null,
    sectionId: null,
    parentId: null,
    notes: null,
    status: "todo",
    priority: 0,
    tags: [],
    dueDate: null,
    startDate: null,
    dueTime: null,
    duePrayer: null,
    duePrayerOffset: null,
    recurrence: null,
    assigneeId: null,
    sortOrder: top + 1,
    completedAt: null,
    createdAt: now(),
    updatedAt: now(),
    ...fields,
  };
  tasks.push(task);
  return task;
}

function deleteTask(id) {
  for (const child of tasks.filter((t) => t.parentId === id)) deleteTask(child.id);
  const at = tasks.findIndex((t) => t.id === id);
  if (at >= 0) tasks.splice(at, 1);
  reminders.delete(id);
  comments.delete(id);
}

/** POST /v1/sync, for what the web app sends through it: sections and reminders. */
function sync(mutations = []) {
  const results = mutations.map((m) => {
    const id = m.id ?? m.data?.id;
    if (m.entity === "section") {
      const owner = projectById(m.data?.projectId) ?? projects.find((p) => p.sections.some((s) => s.id === id));
      if (!owner) return { id, status: "rejected", message: "No such project" };
      owner.sections = owner.sections.filter((s) => s.id !== id);
      if (m.op === "upsert") owner.sections.push({ createdAt: now(), ...m.data, updatedAt: now() });
      else for (const t of tasks) if (t.sectionId === id) t.sectionId = null;
      return { id, status: "applied" };
    }
    if (m.entity === "reminder") {
      const taskId = m.data?.taskId ?? [...reminders.entries()].find(([, list]) => list.some((r) => r.id === id))?.[0];
      if (!taskId) return { id, status: "applied" };
      const list = remindersOf(taskId).filter((r) => r.id !== id);
      if (m.op === "upsert") list.push({ ...m.data, updatedAt: now() });
      reminders.set(taskId, list);
      return { id, status: "applied" };
    }
    return { id, status: "applied" };
  });
  return { results };
}

const ok = (body) => ({ status: 200, body });
const missing = () => ({ status: 404, body: { error: { code: "not_found", message: "Not found" } } });

/** The answer to one request, as `{ status, body }`; GETs the demo already answers go to it. */
function handle(method, url, body) {
  const u = new URL(url);
  const path = u.pathname;
  let m;

  if (path === "/v1/me") {
    if (method === "PATCH") {
      const { settings, ...rest } = body ?? {};
      Object.assign(me, rest);
      if (settings) me.settings = { ...me.settings, ...settings };
    }
    return ok(me);
  }
  if (path === "/v1/auth/logout") return ok({});
  if (path === "/v1/realtime/ticket") return ok({ ticket: "preview" });

  // Projects
  if (path === "/v1/projects") {
    if (method === "POST") {
      const p = { id: newId("p"), ownerId: me.id, parentId: null, kind: "project", role: "owner", view: "list", archivedAt: null, sortOrder: projects.length, createdAt: now(), updatedAt: now(), sections: [], name: body?.name ?? "" };
      projects.push(p);
      return ok(projectOut(p));
    }
    return ok({ projects: projects.map(projectOut) });
  }
  if ((m = path.match(/^\/v1\/projects\/([^/]+)$/))) {
    const p = projectById(decodeURIComponent(m[1]));
    if (!p) return missing();
    if (method === "PATCH") Object.assign(p, body, { updatedAt: now() });
    if (method === "DELETE") {
      for (const t of tasks.filter((x) => x.projectId === p.id)) deleteTask(t.id);
      projects.splice(projects.indexOf(p), 1);
      return { status: 204, body: null };
    }
    return ok(projectOut(p));
  }
  if ((m = path.match(/^\/v1\/projects\/[^/]+\/invites$/)) && method === "POST") {
    return ok({ id: newId("i"), code: "ZIMAM-DEMO", role: body?.role ?? "editor", createdAt: now(), expiresAt: null });
  }

  // Tasks
  if (path === "/v1/tasks" && method === "POST") return ok(newTask(body ?? {}));
  if ((m = path.match(/^\/v1\/tasks\/([^/]+)\/complete$/))) {
    const t = taskById(decodeURIComponent(m[1]));
    if (!t) return missing();
    Object.assign(t, { status: "done", completedAt: now(), updatedAt: now() });
    return ok(t);
  }
  if ((m = path.match(/^\/v1\/tasks\/([^/]+)$/)) && method !== "GET") {
    const t = taskById(decodeURIComponent(m[1]));
    if (!t) return missing();
    if (method === "DELETE") {
      deleteTask(t.id);
      return { status: 204, body: null };
    }
    Object.assign(t, body, { updatedAt: now() });
    if (body?.status === "todo") t.completedAt = null;
    if (body?.status === "done" && !t.completedAt) t.completedAt = now();
    return ok(t);
  }
  if ((m = path.match(/^\/v1\/tasks\/([^/]+)\/reminders$/))) return ok({ reminders: remindersOf(decodeURIComponent(m[1])) });
  if ((m = path.match(/^\/v1\/tasks\/([^/]+)\/comments$/))) {
    const taskId = decodeURIComponent(m[1]);
    const list = comments.get(taskId) ?? [];
    if (method === "POST") {
      list.push({ id: newId("c"), taskId, authorId: me.id, authorName: me.name, body: body?.body ?? "", createdAt: now() });
      comments.set(taskId, list);
      return ok(list.at(-1));
    }
    return ok({ comments: list });
  }
  if ((m = path.match(/^\/v1\/comments\/([^/]+)$/)) && method === "DELETE") {
    for (const [taskId, list] of comments) comments.set(taskId, list.filter((c) => c.id !== decodeURIComponent(m[1])));
    return { status: 204, body: null };
  }
  if (path === "/v1/sync") return ok(sync(body?.mutations));

  // The assistant: a few steps for «تقسيم إلى خطوات»; the rest as the demo answers it.
  if (path === "/v1/assistant/breakdown") {
    return ok({ subtasks: ["تحديد المطلوب بدقة", "جمع ما يلزم من معلومات", "إنجاز الجزء الأول", "المراجعة والتسليم"].map((title) => ({ title })) });
  }

  return answer(method, url);
}

const realFetch = globalThis.fetch.bind(globalThis);
globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (!url.startsWith(API)) return realFetch(input, init);
  const method = (init.method ?? (typeof input === "object" && "method" in input ? input.method : "GET")).toUpperCase();
  let body = null;
  if (typeof init.body === "string") {
    try {
      body = JSON.parse(init.body);
    } catch {
      body = null;
    }
  }
  // A moment's wait, as a network has, so the app's loading states show as they do for real.
  await new Promise((resolve) => setTimeout(resolve, 80));
  const { status, body: out } = handle(method, url, body);
  if (status === 204 || out === null) return new Response(null, { status: 204 });
  return new Response(JSON.stringify(out), { status, headers: { "content-type": "application/json" } });
};
