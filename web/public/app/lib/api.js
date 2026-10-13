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
// (no inline or third-party script except Apple's sign-in), DOM built with textContent only, and an
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
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/** Arabic text for the API's stable English error codes. */
const MESSAGES = {
  unauthorized: "انتهت الجلسة. سجّل الدخول مرة أخرى.",
  invalid_token: "تعذّر التحقق من حساب أبل. حاول مرة أخرى.",
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
  if (body !== undefined) headers["Content-Type"] = "application/json";

  let response;
  try {
    response = await fetch(apiBase() + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      credentials: "omit",
    });
  } catch {
    throw new ApiError(0, "network", "Network error");
  }

  if (response.status === 204) return null;
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    const code = data?.error?.code ?? (response.status === 401 ? "unauthorized" : "internal");
    if (response.status === 401 && path !== "/v1/auth/apple") {
      session.clear();
      onUnauthorized();
    }
    throw new ApiError(response.status, code, data?.error?.message ?? response.statusText);
  }
  return data;
}

const query = (params) => {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) if (value != null && value !== "") search.set(key, value);
  const text = search.toString();
  return text ? `?${text}` : "";
};

export const api = {
  signIn: (identityToken, nonce) => request("POST", "/v1/auth/apple", { identityToken, nonce, device: "web" }),
  signOut: () => request("POST", "/v1/auth/logout"),
  me: () => request("GET", "/v1/me"),
  projects: () => request("GET", "/v1/projects"),
  project: (id) => request("GET", `/v1/projects/${encodeURIComponent(id)}`),
  tasks: (params = {}) => request("GET", `/v1/tasks${query({ limit: 500, ...params })}`),
  createTask: (task) => request("POST", "/v1/tasks", task),
  completeTask: (id) => request("POST", `/v1/tasks/${encodeURIComponent(id)}/complete`),
  reopenTask: (id) => request("PATCH", `/v1/tasks/${encodeURIComponent(id)}`, { status: "todo" }),
  deleteTask: (id) => request("DELETE", `/v1/tasks/${encodeURIComponent(id)}`),
};
