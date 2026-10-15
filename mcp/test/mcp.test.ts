import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import type { AssistantTask, Outcome, TaskFields, ZimamBackend } from "../src/backend";
import { GOOGLE_CALLBACK_SCRIPT, googleAuthUrl } from "../src/consent";
import { createWorker } from "../src/index";

const ORIGIN = env.MCP_ORIGIN;
const REDIRECT = "https://claude.ai/api/mcp/auth_callback";

/**
 * Records calls. Accepts the Apple token "good:<handle>" (user-1) and the Google token
 * "google:<handle>" (user-2) only for the consent page they were signed for.
 */
class FakeBackend implements ZimamBackend {
  calls: { method: string; userId: string; args: unknown }[] = [];

  async signInWithApple(identityToken: string, nonce: string) {
    return identityToken === `good:${nonce}`
      ? { ok: true as const, value: { userId: "user-1", name: "فهد" } }
      : { ok: false as const, error: { code: "invalid_token", message: "rejected" } };
  }
  async signInWithGoogle(idToken: string, nonce: string) {
    return idToken === `google:${nonce}`
      ? { ok: true as const, value: { userId: "user-2", name: "نورة" } }
      : { ok: false as const, error: { code: "invalid_token", message: "rejected" } };
  }
  private record<T>(method: string, userId: string, args: unknown, value: T): Promise<Outcome<T>> {
    this.calls.push({ method, userId, args });
    return Promise.resolve({ ok: true, value });
  }
  private task(fields: TaskFields & { id?: string }): AssistantTask {
    return {
      id: fields.id ?? "11111111-1111-4111-8111-111111111111",
      title: fields.title ?? "مهمة",
      notes: null,
      status: fields.status ?? "todo",
      priority: fields.priority ?? "none",
      tags: [],
      projectId: null,
      project: null,
      parentId: null,
      due: null,
      prayer: null,
      recurrence: null,
      completedAt: null,
    };
  }
  listTasks = (userId: string, filter: object) => this.record("listTasks", userId, filter, [this.task({})]);
  createTask = (userId: string, fields: TaskFields) => this.record("createTask", userId, fields, this.task(fields));
  updateTask = (userId: string, id: string, fields: TaskFields) =>
    this.record("updateTask", userId, { id, ...fields }, this.task({ id, ...fields }));
  completeTask = (userId: string, id: string) => this.record("completeTask", userId, { id }, this.task({ id, status: "done" }));
  listProjects = (userId: string) => this.record("listProjects", userId, {}, []);
  getAgenda = (userId: string, request: object) =>
    this.record("getAgenda", userId, request, { timeZone: "Asia/Riyadh", hasLocation: false, overdue: [], days: [] });
}

let backend: FakeBackend;
let worker: ReturnType<typeof createWorker>;

beforeEach(() => {
  backend = new FakeBackend();
  const shared = backend;
  worker = createWorker(() => shared);
});

async function send(path: string, init: RequestInit = {}, vars: Partial<typeof env> = {}) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(new Request(`${ORIGIN}${path}`, { redirect: "manual", ...init }), { ...env, ...vars }, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function sha256Hex(text: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const base64url = (bytes: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function registerClient() {
  const response = await send("/oauth/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      client_name: "Claude",
      redirect_uris: [REDIRECT],
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
    }),
  });
  expect(response.status).toBe(201);
  return ((await response.json()) as { client_id: string }).client_id;
}

/** Runs the browser part of the flow and returns the redirect back to the client. */
async function authorize(
  clientId: string,
  options: {
    scopes?: string[];
    decision?: "approve" | "deny";
    provider?: "apple" | "google";
    token?: (handle: string) => string;
    vars?: Partial<typeof env>;
  } = {},
) {
  const verifier = crypto.randomUUID() + crypto.randomUUID();
  const challenge = base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  const query = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: REDIRECT,
    state: "state-123",
    code_challenge: challenge,
    code_challenge_method: "S256",
    scope: "tasks:read tasks:write",
    resource: `${ORIGIN}/mcp`,
  });
  const page = await send(`/authorize?${query}`, {}, options.vars);
  expect(page.status).toBe(200);
  const html = await page.text();
  const handle = html.match(/name="handle" value="([^"]+)"/)![1]!;
  const cookie = page.headers
    .getSetCookie()
    .map((c) => c.split(";")[0])
    .join("; ");

  const form = new URLSearchParams({
    handle,
    decision: options.decision ?? "approve",
    id_token: (options.token ?? ((h) => (options.provider === "google" ? `google:${h}` : `good:${h}`)))(handle),
  });
  if (options.provider) form.set("provider", options.provider);
  for (const scope of options.scopes ?? ["tasks:read", "tasks:write"]) form.append("scope", scope);
  const response = await send("/authorize", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: cookie },
    body: form,
  });
  return { response, verifier, html };
}

async function exchange(clientId: string, location: string, verifier: string) {
  const code = new URL(location).searchParams.get("code")!;
  const response = await send("/oauth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      redirect_uri: REDIRECT,
      client_id: clientId,
      code_verifier: verifier,
      resource: `${ORIGIN}/mcp`,
    }),
  });
  expect(response.status).toBe(200);
  return (await response.json()) as { access_token: string; scope: string };
}

async function connect(scopes?: string[], provider?: "apple" | "google") {
  const clientId = await registerClient();
  const { response, verifier } = await authorize(clientId, { scopes, provider });
  expect(response.status).toBe(302);
  return (await exchange(clientId, response.headers.get("Location")!, verifier)).access_token;
}

let rpcId = 0;
async function rpc(token: string, method: string, params: object = {}) {
  const response = await send("/mcp", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      "MCP-Protocol-Version": "2025-06-18",
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
  });
  expect(response.status).toBe(200);
  return (await response.json()) as { result?: any; error?: { message: string } };
}

const initialize = (token: string) =>
  rpc(token, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });

describe("Zimam MCP server", () => {
  it("asks unauthenticated clients to sign in and publishes OAuth metadata", async () => {
    const response = await send("/mcp", { method: "POST", body: "{}" });
    expect(response.status).toBe(401);
    expect(response.headers.get("WWW-Authenticate")).toContain("resource_metadata");

    const metadata = (await (await send("/.well-known/oauth-authorization-server")).json()) as Record<string, unknown>;
    expect(metadata).toMatchObject({
      issuer: ORIGIN,
      authorization_endpoint: `${ORIGIN}/authorize`,
      token_endpoint: `${ORIGIN}/oauth/token`,
      registration_endpoint: `${ORIGIN}/oauth/register`,
    });
  });

  it("shows an Arabic consent page naming the client and where access goes", async () => {
    const clientId = await registerClient();
    const { html } = await authorize(clientId, { decision: "deny" });
    expect(html).toContain('dir="rtl"');
    expect(html).toContain("ربط Claude بحسابك في زمام");
    expect(html).toContain("claude.ai");
    expect(html).toContain("appleid.auth.js");
    expect(html).toContain("المتابعة بحساب أبل");
    expect(html).toContain("المتابعة بحساب قوقل");
    // Our own Google button: no Google script on the page.
    expect(html).not.toContain("accounts.google.com/gsi");
  });

  it("sends Google's sign-in back to /google-callback with an ID token for this consent page", async () => {
    const clientId = await registerClient();
    const { html } = await authorize(clientId, { decision: "deny" });
    const handle = html.match(/name="handle" value="([^"]+)"/)![1]!;
    const authUrl = JSON.parse(html.match(/new URL\(("https:\/\/accounts\.google\.com[^"]+")\)/)![1]!) as string;
    const url = new URL(authUrl);
    expect(`${url.origin}${url.pathname}`).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(Object.fromEntries(url.searchParams)).toEqual({
      client_id: env.GOOGLE_WEB_CLIENT_ID,
      redirect_uri: `${ORIGIN}/google-callback`,
      response_type: "id_token",
      scope: "openid email profile",
      nonce: await sha256Hex(handle),
      prompt: "select_account",
      hl: "ar",
    });
    expect(googleAuthUrl("client", ORIGIN, "n")).toContain(encodeURIComponent(`${ORIGIN}/google-callback`));
  });

  it("serves the Google callback page with its script as a separate file and a strict CSP", async () => {
    const page = await send("/google-callback");
    expect(page.status).toBe(200);
    const csp = page.headers.get("Content-Security-Policy")!;
    expect(csp).toContain("script-src 'self'");
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("frame-ancestors 'none'");
    // The whole-tab fallback posts the consent form, then /authorize redirects to the client.
    expect(csp).not.toContain("form-action");
    expect(page.headers.get("Referrer-Policy")).toBe("no-referrer");
    const html = await page.text();
    expect(html).toContain('dir="rtl"');
    const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)];
    expect(scripts).toHaveLength(1);
    expect(scripts[0]![1]).toContain('src="/google-callback.js"');
    expect(scripts[0]![2]!.trim()).toBe("");

    const script = await send("/google-callback.js");
    expect(script.status).toBe(200);
    expect(script.headers.get("Content-Type")).toContain("text/javascript");
    const code = await script.text();
    expect(code).toBe(GOOGLE_CALLBACK_SCRIPT);
    expect(code).toContain('"zimam-google-signin"');
    expect(code).toContain('form.action = "/authorize"');
    expect(code).toContain("history.replaceState");
  });

  it("hides Sign in with Google when no web client ID is configured", async () => {
    const clientId = await registerClient();
    const { html } = await authorize(clientId, { decision: "deny", vars: { GOOGLE_WEB_CLIENT_ID: "" } });
    expect(html).toContain("appleid.auth.js");
    expect(html).not.toContain("accounts.google.com");
    expect(html).not.toContain("قوقل");
  });

  it("links an account through Sign in with Google", async () => {
    const token = await connect(undefined, "google");
    await initialize(token);
    await rpc(token, "tools/call", { name: "list_projects", arguments: {} });
    expect(backend.calls.at(-1)).toEqual({ method: "listProjects", userId: "user-2", args: {} });
  });

  it("refuses a Google token that was not issued for this consent page, or an Apple token posted as Google", async () => {
    const clientId = await registerClient();
    const other = await authorize(clientId, { provider: "google", token: () => "google:another-page" });
    expect(other.response.status).toBe(401);
    expect(await other.response.text()).toContain("حساب قوقل");
    const mixed = await authorize(clientId, { provider: "google", token: (h) => `good:${h}` });
    expect(mixed.response.status).toBe(401);
  });

  it("links an account through Sign in with Apple and serves all seven tools", async () => {
    const token = await connect();
    const init = await initialize(token);
    expect(init.result.serverInfo.name).toBe("zimam");
    expect(init.result.instructions).toContain("Hijri");

    const list = await rpc(token, "tools/list");
    expect(list.result.tools.map((t: { name: string }) => t.name).sort()).toEqual(
      ["complete_task", "create_task", "get_agenda", "list_projects", "list_tasks", "search_tasks", "update_task"].sort(),
    );

    const created = await rpc(token, "tools/call", {
      name: "create_task",
      arguments: { title: "مراجعة العقد", dueDate: "2026-10-15", duePrayer: "maghrib", duePrayerOffset: 20, priority: "high" },
    });
    expect(created.result.isError).toBeFalsy();
    expect(JSON.parse(created.result.content[0].text)).toMatchObject({ title: "مراجعة العقد", priority: "high" });
    expect(backend.calls.at(-1)).toEqual({
      method: "createTask",
      userId: "user-1",
      args: { title: "مراجعة العقد", dueDate: "2026-10-15", duePrayer: "maghrib", duePrayerOffset: 20, priority: "high" },
    });

    await rpc(token, "tools/call", { name: "search_tasks", arguments: { query: "عقد" } });
    expect(backend.calls.at(-1)).toEqual({ method: "listTasks", userId: "user-1", args: { query: "عقد", status: "open", limit: undefined } });

    await rpc(token, "tools/call", { name: "update_task", arguments: { id: "abc", dueDate: "2026-10-16" } });
    expect(backend.calls.at(-1)).toMatchObject({ method: "updateTask", args: { id: "abc", dueDate: "2026-10-16" } });
  });

  it("rejects bad tool input before it reaches the backend", async () => {
    const token = await connect();
    const bad = await rpc(token, "tools/call", { name: "create_task", arguments: { title: "x", dueDate: "15/10/2026" } });
    const failed = bad.error !== undefined || bad.result?.isError === true;
    expect(failed).toBe(true);
    expect(backend.calls).toEqual([]);
  });

  it("gives a read-only grant only the read tools", async () => {
    const token = await connect(["tasks:read"]);
    const list = await rpc(token, "tools/list");
    expect(list.result.tools.map((t: { name: string }) => t.name).sort()).toEqual(
      ["get_agenda", "list_projects", "list_tasks", "search_tasks"].sort(),
    );
  });

  it("refuses an Apple token that was not issued for this consent page", async () => {
    const clientId = await registerClient();
    const { response } = await authorize(clientId, { token: () => "good:another-page" });
    expect(response.status).toBe(401);
  });

  it("sends the client access_denied when the user declines", async () => {
    const clientId = await registerClient();
    const { response } = await authorize(clientId, { decision: "deny" });
    expect(response.status).toBe(302);
    const location = new URL(response.headers.get("Location")!);
    expect(location.origin + location.pathname).toBe(REDIRECT);
    expect(location.searchParams.get("error")).toBe("access_denied");
    expect(location.searchParams.get("state")).toBe("state-123");
  });

  it("rejects a consent form posted without the browser's binding cookie", async () => {
    const clientId = await registerClient();
    const query = new URLSearchParams({
      response_type: "code",
      client_id: clientId,
      redirect_uri: REDIRECT,
      state: "s",
      code_challenge: "x".repeat(43),
      code_challenge_method: "S256",
      resource: `${ORIGIN}/mcp`,
    });
    const page = await (await send(`/authorize?${query}`)).text();
    const handle = page.match(/name="handle" value="([^"]+)"/)![1]!;
    const response = await send("/authorize", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ handle, decision: "approve", id_token: `good:${handle}`, scope: "tasks:read" }),
    });
    expect(response.status).toBe(400);
  });
});
