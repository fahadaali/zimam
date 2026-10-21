// REST client for the Zimam API (api/DEVELOPMENT.md). Every signed-in call sends
// `Authorization: Bearer <session token>`; a 401 ends the session and returns to sign-in.

const TOKEN_KEY = "zimam.session";

/** The API for this site: api.zimam.app for zimam.app, the workers.dev API everywhere else. */
export function apiBase(hostname = location.hostname) {
  if (hostname === "zimam.app" || hostname.endsWith(".zimam.app")) return "https://api.zimam.app";
  return "https://zimam.fahad2ao.workers.dev";
}

// The session token lives in localStorage so the app stays signed in across tabs and restarts, like
// the Apple app. sessionStorage would not make it safer: script that runs in this origin (the only
// way to read either store) can read both. What protects it is the strict CSP in public/_headers
// (no inline or third-party script except Apple's and Google's sign-in), DOM built with textContent only, and an
// opaque token the server can revoke: signing out deletes it on the server and here.
export const session = {
  get() {
    try {
      return localStorage.getItem(TOKEN_KEY);
    } catch {
      return null;
    }
  },
  set(token) {
    try {
      localStorage.setItem(TOKEN_KEY, token);
    } catch {
      /* storage blocked: the session lasts for this page only */
    }
    memoryToken = token;
  },
  clear() {
    memoryToken = null;
    try {
      localStorage.removeItem(TOKEN_KEY);
    } catch {
      /* nothing stored */
    }
  },
};
let memoryToken = null;
const currentToken = () => session.get() ?? memoryToken;

export class ApiError extends Error {
  constructor(status, code, message, details = null) {
    super(message);
    this.status = status;
    this.code = code;
    /** The whole `error` object, for codes with more fields (ai_quota_exceeded: limit, resetsOn). */
    this.details = details;
  }
}

/** Arabic text for the API's stable English error codes. */
const MESSAGES = {
  unauthorized: "انتهت الجلسة. سجّل الدخول مرة أخرى.",
  invalid_token: "تعذّر التحقق من حسابك. حاول مرة أخرى.",
  google_unavailable: "تسجيل الدخول بحساب قوقل غير متاح الآن. استعمل حساب أبل.",
  invalid: "تحقق من البيانات المدخلة ثم حاول مرة أخرى.",
  forbidden: "لا تملك صلاحية هذا التعديل.",
  not_found: "لم نجد هذا العنصر، وربما حُذف.",
  stale: "تغيّرت المهمة من جهاز آخر. حدّث الصفحة ثم حاول مرة أخرى.",
  gone: "حُذف هذا العنصر.",
  internal: "حدث خطأ في الخادم. حاول بعد قليل.",
  network: "تعذّر الاتصال بالخادم. تحقق من اتصالك ثم حاول مرة أخرى.",
};

export function errorText(error) {
  return MESSAGES[error?.code] ?? MESSAGES.internal;
}

let onUnauthorized = () => {};
export function whenSignedOut(handler) {
  onUnauthorized = handler;
}

export async function request(method, path, body) {
  const headers = { Accept: "application/json" };
  const token = currentToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  // A FormData body (a file upload) sets its own multipart Content-Type with the boundary. A Blob
  // (the account photo) goes as its raw bytes, with its own type.
  const form = typeof FormData !== "undefined" && body instanceof FormData;
  const raw = typeof Blob !== "undefined" && body instanceof Blob;
  if (raw) headers["Content-Type"] = body.type || "application/octet-stream";
  else if (body !== undefined && !form) headers["Content-Type"] = "application/json";

  let response;
  try {
    response = await fetch(apiBase() + path, {
      method,
      headers,
      body: body === undefined ? undefined : form || raw ? body : JSON.stringify(body),
      credentials: "omit",
    });
  } catch {
    throw new ApiError(0, "network", "Network error");
  }

  if (response.status === 204) return null;
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    const code = data?.error?.code ?? (response.status === 401 ? "unauthorized" : "internal");
    if (response.status === 401 && path !== "/v1/auth/apple" && path !== "/v1/auth/google") {
      session.clear();
      onUnauthorized();
    }
    throw new ApiError(response.status, code, data?.error?.message ?? response.statusText, data?.error ?? null);
  }
  return data;
}

/** A signed-in GET that answers a file (an attachment): its Blob, or the same ApiError as `request`. */
export async function requestBlob(path) {
  const headers = {};
  const token = currentToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  let response;
  try {
    response = await fetch(apiBase() + path, { headers, credentials: "omit" });
  } catch {
    throw new ApiError(0, "network", "Network error");
  }
  if (response.ok) return response.blob();
  const data = await response.json().catch(() => null);
  if (response.status === 401) {
    session.clear();
    onUnauthorized();
  }
  throw new ApiError(response.status, data?.error?.code ?? (response.status === 401 ? "unauthorized" : "internal"), data?.error?.message ?? "");
}

const query = (params) => {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) if (value != null && value !== "") search.set(key, value);
  const text = search.toString();
  return text ? `?${text}` : "";
};

/** The largest page GET /v1/tasks answers, and how many pages a list reads before it stops. */
export const TASK_PAGE_SIZE = 500;
export const TASK_PAGE_LIMIT = 20;

/**
 * Reads a paged list to its end: asks `fetchPage(offset)` for `{ tasks }` pages while a page comes
 * back full, up to `maxPages`, and returns `{ tasks }` with every page joined in order.
 */
export async function fetchAllPages(fetchPage, { pageSize = TASK_PAGE_SIZE, maxPages = TASK_PAGE_LIMIT } = {}) {
  const tasks = [];
  for (let page = 0; page < maxPages; page += 1) {
    const { tasks: batch = [] } = (await fetchPage(page * pageSize)) ?? {};
    tasks.push(...batch);
    if (batch.length < pageSize) break;
  }
  return { tasks };
}

/** Every task matching `params`, read from GET /v1/tasks a full page at a time. */
export const allTasks = (params = {}) =>
  fetchAllPages((offset) => request("GET", `/v1/tasks${query({ ...params, limit: TASK_PAGE_SIZE, offset })}`));

export const api = {
  /** `authorizationCode` and `redirectUri` let the API keep Apple's refresh token, revoked when the account is deleted. */
  signIn: (identityToken, nonce, { authorizationCode, redirectUri } = {}) =>
    request("POST", "/v1/auth/apple", { identityToken, nonce, authorizationCode, redirectUri, device: "web" }),
  signInWithGoogle: (idToken, nonce) => request("POST", "/v1/auth/google", { idToken, nonce, device: "web" }),
  signOut: () => request("POST", "/v1/auth/logout"),
  me: () => request("GET", "/v1/me"),
  updateMe: (fields) => request("PATCH", "/v1/me", fields),
  deleteMe: () => request("DELETE", "/v1/me"),
  /** The account photo: JPEG or PNG bytes up to 1 MB (avatar.js makes a 512×512 JPEG); answers the user. */
  uploadAvatar: (blob) => request("PUT", "/v1/me/avatar", blob.type ? blob : new Blob([blob], { type: "image/jpeg" })),
  removeAvatar: () => request("DELETE", "/v1/me/avatar"),
  /** The photo's bytes as a Blob; ApiError 404 when there is none. `version` (avatarVersion) only busts the browser's cache. */
  avatar: (version) => requestBlob(`/v1/me/avatar${query({ v: version })}`),
  projects: () => request("GET", "/v1/projects"),
  project: (id) => request("GET", `/v1/projects/${encodeURIComponent(id)}`),
  createProject: (name) => request("POST", "/v1/projects", { name }),
  task: (id) => request("GET", `/v1/tasks/${encodeURIComponent(id)}`),
  tasks: (params = {}) => allTasks(params),
  createTask: (task) => request("POST", "/v1/tasks", task),
  completeTask: (id) => request("POST", `/v1/tasks/${encodeURIComponent(id)}/complete`),
  patchTask: (id, fields) => request("PATCH", `/v1/tasks/${encodeURIComponent(id)}`, fields),
  reopenTask: (id) => request("PATCH", `/v1/tasks/${encodeURIComponent(id)}`, { status: "todo" }),
  deleteTask: (id) => request("DELETE", `/v1/tasks/${encodeURIComponent(id)}`),
  /** A single-use ticket for the realtime socket (lib/realtime.js); browsers cannot send headers on it. */
  realtimeTicket: () => request("POST", "/v1/realtime/ticket"),
};
