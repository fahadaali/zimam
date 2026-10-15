import { createExecutionContext, createMessageBatch, getQueueResult } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import { sha256Hex } from "../src/auth/crypto";
import type { ImportDeps, ImportMessage } from "../src/imports/jobs";
import { PENDING_TTL_MS, STATE_TTL_MS } from "../src/imports/oauth";
import { TRELLO_PAGE_SCRIPT } from "../src/routes/import-oauth";
import { handleImportBatch, IMPORT_QUEUE } from "../src/imports/queue";
import { fakeAi, signIn, testAppleKeys, testGoogleKeys } from "./helpers";

// MARK: Fakes

let sent: ImportMessage[] = [];
/** The providers: token endpoints and APIs, by URL. */
let provider: (url: URL, init?: RequestInit) => Response | Promise<Response>;
const seen: { url: URL; init?: RequestInit }[] = [];

const importDeps = (): ImportDeps => ({
  enqueue: async (message) => {
    sent.push(structuredClone(message));
  },
  files: env.IMPORT_FILES,
  fetch: async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    seen.push({ url, init });
    return provider(url, init);
  },
});

const app = createApp({ appleKeys: testAppleKeys, googleKeys: testGoogleKeys, ai: () => fakeAi, appleTokens: () => null, imports: importDeps });

/** Every provider's secrets, as `wrangler secret put` would set them. */
const SECRETS = {
  GOOGLE_CLIENT_SECRET: "google-secret",
  MS_CLIENT_ID: "ms-client",
  MS_CLIENT_SECRET: "ms-secret",
  NOTION_CLIENT_ID: "notion-client",
  NOTION_CLIENT_SECRET: "notion-secret",
  TRELLO_API_KEY: "trellokey0123456789abcdef01234567",
  ASANA_CLIENT_ID: "asana-client",
  ASANA_CLIENT_SECRET: "asana-secret",
  TICKTICK_CLIENT_ID: "ticktick-client",
  TICKTICK_CLIENT_SECRET: "ticktick-secret",
};
const WEB = "https://zimam-web.fahad2ao.workers.dev";

beforeEach(() => {
  sent = [];
  seen.length = 0;
  provider = () => new Response("not stubbed", { status: 500 });
});

async function request(
  method: string,
  path: string,
  o: { token?: string; json?: unknown; env?: Record<string, string> } = {},
) {
  const headers = new Headers();
  if (o.token) headers.set("Authorization", `Bearer ${o.token}`);
  let body: string | undefined;
  if (o.json !== undefined) {
    headers.set("Content-Type", "application/json");
    body = JSON.stringify(o.json);
  }
  const response = await app.fetch(new Request(`https://api.zimam.test${path}`, { method, headers, body, redirect: "manual" }), {
    ...env,
    ...SECRETS,
    ...(o.env ?? {}),
  });
  return response;
}

const json = async (response: Response) => response.json() as Promise<Record<string, any>>;

async function start(token: string, source: string, ret = "app", extra: Record<string, string> = {}) {
  const res = await request("GET", `/v1/imports/oauth/${source}/start?return=${encodeURIComponent(ret)}`, { token, env: extra });
  expect(res.status).toBe(200);
  const body = await json(res);
  return { url: new URL(body.url), expiresAt: body.expiresAt as number };
}

/** POST /v1/imports/oauth/confirm as the signed-in user (or no one), with Trello's token when given. */
async function confirm(session: string | undefined, pending: string, o: { token?: string; env?: Record<string, string> } = {}) {
  return request("POST", "/v1/imports/oauth/confirm", {
    token: session,
    json: o.token === undefined ? { pending } : { pending, token: o.token },
    env: o.env,
  });
}

/** The pending id a callback returned with: in the app's query, or in the site's route (the fragment). */
function pendingOf(location: string): string {
  const url = new URL(location);
  const pending = url.searchParams.get("pending") ?? new URLSearchParams(url.hash.split("?")[1] ?? "").get("pending");
  expect(pending).toMatch(/^[A-Za-z0-9_-]{40,}$/);
  return pending!;
}

/** Everything the OAuth flow keeps in D1 for a user, as one string to search. */
async function storedFor(userId: string) {
  const tables = await Promise.all(
    ["import_oauth_states", "import_oauth_pending", "import_jobs"].map((t) => env.DB.prepare(`SELECT * FROM ${t} WHERE user_id = ?`).bind(userId).all()),
  );
  return JSON.stringify(tables.map((t) => t.results));
}

const countJobs = (userId: string) => env.DB.prepare(`SELECT COUNT(*) AS n FROM import_jobs WHERE user_id = ?`).bind(userId).first<number>("n");

async function deliverAll() {
  for (let i = 0; sent.length > 0; i++) {
    if (i > 50) throw new Error("the import never finished");
    const batch = createMessageBatch<ImportMessage>(IMPORT_QUEUE, [{ id: crypto.randomUUID(), timestamp: Date.now(), attempts: 1, body: sent.shift()! }]);
    const ctx = createExecutionContext();
    await handleImportBatch(batch, env, importDeps());
    expect((await getQueueResult(batch, ctx)).retryMessages).toEqual([]);
  }
}

const base64url = (bytes: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Google: the token endpoint (checking the client secret and PKCE) and a calendar with one event. */
function googleServer(challenge: string, accessToken = "ya29.calendar-token") {
  return async (url: URL, init?: RequestInit) => {
    if (url.href === "https://oauth2.googleapis.com/token") {
      const form = new URLSearchParams(String(init?.body));
      const verifier = form.get("code_verifier") ?? "";
      const ok =
        form.get("code") === "good-code" &&
        form.get("client_secret") === "google-secret" &&
        form.get("redirect_uri") === "https://api.zimam.test/v1/imports/oauth/google-calendar/callback" &&
        base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))) === challenge;
      return ok ? Response.json({ access_token: accessToken, expires_in: 3599, token_type: "Bearer" }) : Response.json({ error: "invalid_grant" }, { status: 400 });
    }
    if (new Headers(init?.headers).get("Authorization") !== `Bearer ${accessToken}`) return new Response("", { status: 401 });
    if (url.pathname === "/calendar/v3/users/me/calendarList") {
      return Response.json({ items: [{ id: "me@example.com", summary: "تقويمي", primary: true, selected: true }] });
    }
    if (url.pathname === "/calendar/v3/calendars/me%40example.com/events") {
      const single = url.searchParams.get("singleEvents") === "true";
      return Response.json({
        items: single
          ? [
              { id: "ev1", status: "confirmed", summary: "موعد الطبيب", start: { dateTime: "2026-10-20T08:00:00+03:00" }, end: { dateTime: "2026-10-20T09:00:00+03:00" } },
              { id: "ev2", status: "confirmed", summary: "مؤتمر", start: { date: "2026-11-02" }, end: { date: "2026-11-05" } },
            ]
          : [],
      });
    }
    return new Response("unknown", { status: 404 });
  };
}

// MARK: Tests

describe("OAuth imports", () => {
  it("lists OAuth sources, unavailable until their secrets are set", async () => {
    const { token } = await signIn();
    const without = await app.fetch(new Request("https://api.zimam.test/v1/imports/sources", { headers: { Authorization: `Bearer ${token}` } }), env);
    const listed = (await json(without)).sources as { id: string; input: string; available: boolean }[];
    expect(listed.filter((s) => s.input === "oauth").map((s) => [s.id, s.available])).toEqual([
      ["google-calendar", false],
      ["microsoft-todo", false],
      ["notion", false],
      ["trello", false],
      ["asana", false],
      ["ticktick-api", false],
    ]);
    expect(listed.filter((s) => s.input !== "oauth").every((s) => s.available)).toBe(true);
    const withSecrets = (await json(await request("GET", "/v1/imports/sources", { token }))).sources as { input: string; available: boolean }[];
    expect(withSecrets.filter((s) => s.input === "oauth").every((s) => s.available)).toBe(true);

    const res = await app.fetch(new Request("https://api.zimam.test/v1/imports/oauth/notion/start?return=app", { headers: { Authorization: `Bearer ${token}` } }), env);
    expect(res.status).toBe(503);
    expect((await json(res)).error.code).toBe("source_unavailable");
  });

  it("starts a flow with PKCE and a state kept only as its hash", async () => {
    const { token, userId } = await signIn();
    const { url, expiresAt } = await start(token, "google-calendar");
    expect(url.origin + url.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(Object.fromEntries(url.searchParams)).toMatchObject({
      client_id: "404741015373-ukucah8482ofiuvd9lb4cn4pgqvnfm75.apps.googleusercontent.com",
      redirect_uri: "https://api.zimam.test/v1/imports/oauth/google-calendar/callback",
      response_type: "code",
      scope: "https://www.googleapis.com/auth/calendar.readonly",
      code_challenge_method: "S256",
      access_type: "online",
    });
    expect(expiresAt).toBeGreaterThan(Date.now() + STATE_TTL_MS - 60_000);
    const state = url.searchParams.get("state")!;
    expect(state.length).toBeGreaterThanOrEqual(40);
    const rows = await env.DB.prepare(`SELECT * FROM import_oauth_states WHERE user_id = ?`).bind(userId).all();
    expect(rows.results).toEqual([expect.objectContaining({ state_hash: await sha256Hex(state), source: "google-calendar", return_to: "app" })]);
    expect(JSON.stringify(rows.results)).not.toContain(state);

    // Notion and TickTick: no PKCE; Microsoft: PKCE and its scopes.
    const notion = (await start(token, "notion")).url;
    expect(notion.searchParams.get("owner")).toBe("user");
    expect(notion.searchParams.has("code_challenge")).toBe(false);
    const ms = (await start(token, "microsoft-todo")).url;
    expect(ms.searchParams.get("scope")).toBe("Tasks.Read offline_access");
    expect(ms.searchParams.has("code_challenge")).toBe(true);
    expect((await start(token, "ticktick-api")).url.searchParams.get("scope")).toBe("tasks:read");
  });

  it("refuses unknown sources and return targets, and needs a session", async () => {
    const { token } = await signIn();
    expect((await request("GET", "/v1/imports/oauth/google-calendar/start?return=app")).status).toBe(401);
    expect((await json(await request("GET", "/v1/imports/oauth/todoist-api/start?return=app", { token }))).error.code).toBe("invalid_source");
    const evil = await request("GET", "/v1/imports/oauth/google-calendar/start?return=https://evil.example", { token });
    expect(evil.status).toBe(400);
    expect((await json(evil)).error.code).toBe("invalid_return");
    // A token pasted for an OAuth source is refused: it connects through its flow.
    const pasted = await request("POST", "/v1/imports", { token, json: { source: "notion", token: "secret_0123456789" } });
    expect(pasted.status).toBe(400);
  });

  it("needs «زمام الاحترافية» when plans are enforced, at the start and at the confirm", async () => {
    const { token } = await signIn();
    const res = await request("GET", "/v1/imports/oauth/asana/start?return=app", { token, env: { SUBSCRIPTIONS_ENFORCED: "true" } });
    expect(res.status).toBe(403);
    expect((await json(res)).error.code).toBe("pro_required");

    // Started while free to use, confirmed after enforcement began: no job, and the record waits.
    const { url } = await start(token, "asana");
    provider = (u) => (u.pathname === "/-/oauth_token" ? Response.json({ access_token: "asana-token-123" }) : new Response("", { status: 404 }));
    const callback = await request("GET", `/v1/imports/oauth/asana/callback?code=c&state=${url.searchParams.get("state")}`);
    const pending = pendingOf(callback.headers.get("Location")!);
    const refused = await confirm(token, pending, { env: { SUBSCRIPTIONS_ENFORCED: "true" } });
    expect(refused.status).toBe(403);
    expect((await json(refused)).error.code).toBe("pro_required");
    expect(sent).toEqual([]);
    expect(seen).toEqual([]);
    expect((await confirm(token, pending)).status).toBe(202);
    expect(sent).toEqual([expect.objectContaining({ token: "asana-token-123" })]);
  });

  it("keeps the code at the callback, and exchanges it only when the user confirms", async () => {
    const { token, userId } = await signIn();
    const { url } = await start(token, "google-calendar");
    const state = url.searchParams.get("state")!;
    provider = googleServer(url.searchParams.get("code_challenge")!);

    // Public: no session on the way back from Google. Nothing is exchanged or queued yet.
    const res = await request("GET", `/v1/imports/oauth/google-calendar/callback?code=good-code&state=${state}&scope=x`);
    expect(res.status).toBe(302);
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(res.headers.get("Referrer-Policy")).toBe("no-referrer");
    const location = new URL(res.headers.get("Location")!);
    expect(`${location.protocol}//${location.host}`).toBe("zimam://import-callback");
    expect([...location.searchParams.keys()]).toEqual(["pending", "source"]);
    expect(location.searchParams.get("source")).toBe("google-calendar");
    const pending = pendingOf(location.href);
    expect(seen).toEqual([]);
    expect(sent).toEqual([]);
    expect(await countJobs(userId)).toBe(0);

    // The record: the pending id's hash, the code and its PKCE verifier, for ten minutes.
    const row = await env.DB.prepare(`SELECT * FROM import_oauth_pending WHERE user_id = ?`).bind(userId).first<Record<string, any>>();
    expect(row).toMatchObject({ pending_hash: await sha256Hex(pending), source: "google-calendar", code: "good-code", used_at: null });
    expect(row!.code_verifier).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(row!.expires_at - row!.created_at).toBe(PENDING_TTL_MS);
    expect(await storedFor(userId)).not.toContain(pending);

    // A confirm needs a session.
    expect((await confirm(undefined, pending)).status).toBe(401);

    const confirmed = await confirm(token, pending);
    expect(confirmed.status).toBe(202);
    expect(confirmed.headers.get("Cache-Control")).toBe("no-store");
    const { job } = await json(confirmed);
    expect(job).toMatchObject({ source: "google-calendar", status: "queued" });
    expect(sent).toEqual([{ jobId: job.id, cursor: 0, token: "ya29.calendar-token" }]);

    // Used once: the code and verifier are gone, and the token is in no table.
    const used = await env.DB.prepare(`SELECT * FROM import_oauth_pending WHERE user_id = ?`).bind(userId).first<Record<string, any>>();
    expect(used).toMatchObject({ code: null, code_verifier: null });
    expect(used!.used_at).toBeGreaterThan(0);
    const stored = await storedFor(userId);
    expect(stored).not.toContain("ya29");
    expect(stored).not.toContain("good-code");
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM import_oauth_states WHERE user_id = ?`).bind(userId).first("n")).toBe(0);

    await deliverAll();
    const done = await json(await request("GET", `/v1/imports/${job.id}`, { token }));
    expect(done.job).toMatchObject({ status: "done", source: "google-calendar", counts: { created: 3, failed: 0 } });
    const task = await env.DB.prepare(`SELECT * FROM tasks WHERE owner_id = ? AND title = ?`).bind(userId, "موعد الطبيب").first();
    expect(task).toMatchObject({ due_date: "2026-10-20", due_time: "08:00", start_date: null });
    // A multi-day event keeps its span: the start day reaches the Mutator.
    const span = await env.DB.prepare(`SELECT * FROM tasks WHERE owner_id = ? AND title = ?`).bind(userId, "مؤتمر").first();
    expect(span).toMatchObject({ start_date: "2026-11-02", due_date: "2026-11-04", due_time: null });

    // The pending record is single use: 410, and nothing more is queued.
    const again = await confirm(token, pending);
    expect(again.status).toBe(410);
    expect((await json(again)).error).toEqual({ code: "expired", message: expect.stringContaining("استُعمل من قبل") });
    expect(sent).toEqual([]);

    // The state is single use too.
    const back = await request("GET", `/v1/imports/oauth/google-calendar/callback?code=good-code&state=${state}`);
    expect(back.status).toBe(400);
    expect(back.headers.get("Content-Type")).toMatch(/^text\/html/);
    expect(await back.text()).toContain("انتهت صلاحية طلب الربط");
  });

  it("never imports into the account that started the flow when someone else confirms (login CSRF)", async () => {
    // The attacker starts a flow on their own account and sends Google's link to the victim.
    const attacker = await signIn();
    const victim = await signIn();
    const { url } = await start(attacker.token, "google-calendar");
    provider = googleServer(url.searchParams.get("code_challenge")!, "ya29.victim-token");

    // The victim consents; Google returns the victim's browser to the callback, which keeps the
    // code for the attacker's flow and hands the pending id to the victim's browser only.
    const res = await request("GET", `/v1/imports/oauth/google-calendar/callback?code=good-code&state=${url.searchParams.get("state")}`);
    const pending = pendingOf(res.headers.get("Location")!);

    // The victim's client confirms as the victim: 404, the same answer as an id that never existed.
    const refused = await confirm(victim.token, pending);
    expect(refused.status).toBe(404);
    const unknown = await confirm(victim.token, "x".repeat(43));
    expect(unknown.status).toBe(404);
    const refusedBody = await json(refused);
    expect(refusedBody).toEqual(await json(unknown));
    expect(refusedBody.error.message).toContain("لا يخص حسابك");

    // Not signed in at all: the client asks to sign in first.
    expect((await confirm(undefined, pending)).status).toBe(401);

    // Nothing was exchanged or queued, for either account.
    expect(seen).toEqual([]);
    expect(sent).toEqual([]);
    expect(await countJobs(attacker.userId)).toBe(0);
    expect(await countJobs(victim.userId)).toBe(0);
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM import_oauth_pending WHERE user_id = ?`).bind(victim.userId).first("n")).toBe(0);
  });

  it("refuses an expired pending record with 410, without exchanging its code", async () => {
    const { token, userId } = await signIn();
    const { url } = await start(token, "asana");
    provider = () => Response.json({ access_token: "asana-token-123" });
    const res = await request("GET", `/v1/imports/oauth/asana/callback?code=c&state=${url.searchParams.get("state")}`);
    const pending = pendingOf(res.headers.get("Location")!);
    await env.DB.prepare(`UPDATE import_oauth_pending SET expires_at = ? WHERE user_id = ?`).bind(Date.now() - 1, userId).run();

    const late = await confirm(token, pending);
    expect(late.status).toBe(410);
    expect((await json(late)).error.message).toMatch(/[؀-ۿ]/);
    expect(seen).toEqual([]);
    expect(sent).toEqual([]);

    // Swept by the next flow: then it is simply unknown.
    await start(token, "asana");
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM import_oauth_pending WHERE user_id = ?`).bind(userId).first("n")).toBe(0);
    expect((await confirm(token, pending)).status).toBe(404);
    expect((await confirm(token, "")).status).toBe(400);
  });

  it("returns to the site with the pending id in the fragment, and reports a refusal or a failed exchange", async () => {
    const { token, userId } = await signIn();
    const denied = await start(token, "microsoft-todo", WEB);
    const res = await request("GET", `/v1/imports/oauth/microsoft-todo/callback?error=access_denied&error_description=x&state=${denied.url.searchParams.get("state")}`);
    expect(res.headers.get("Location")).toBe(`${WEB}/app/#/import?error=denied`);
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM import_oauth_pending WHERE user_id = ?`).bind(userId).first("n")).toBe(0);

    const failing = await start(token, "microsoft-todo", WEB);
    provider = () => Response.json({ error: "invalid_grant" }, { status: 400 });
    const res2 = await request("GET", `/v1/imports/oauth/microsoft-todo/callback?code=bad-code&state=${failing.url.searchParams.get("state")}`);
    const location = new URL(res2.headers.get("Location")!);
    expect(location.origin + location.pathname).toBe(`${WEB}/app/`);
    expect(location.search).toBe("");
    expect(location.hash).toMatch(/^#\/import\?pending=[A-Za-z0-9_-]{40,}&source=microsoft-todo$/);

    const confirmed = await confirm(token, pendingOf(location.href));
    expect(confirmed.status).toBe(502);
    expect((await json(confirmed)).error.code).toBe("exchange_failed");
    // Basic auth for Notion and TickTick, body credentials for Microsoft.
    const body = new URLSearchParams(String(seen.at(-1)!.init!.body));
    expect(body.get("client_secret")).toBe("ms-secret");
    expect(body.get("code")).toBe("bad-code");
    expect(body.get("code_verifier")).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(sent).toEqual([]);
    expect(await storedFor(userId)).not.toContain("bad-code");
  });

  it("refuses a state for another source, or one that expired", async () => {
    const { token, userId } = await signIn();
    const { url } = await start(token, "notion");
    const state = url.searchParams.get("state")!;
    expect((await request("GET", `/v1/imports/oauth/asana/callback?code=c&state=${state}`)).status).toBe(400);

    const late = await start(token, "notion");
    await env.DB.prepare(`UPDATE import_oauth_states SET expires_at = ? WHERE user_id = ?`).bind(Date.now() - 1, userId).run();
    expect((await request("GET", `/v1/imports/oauth/notion/callback?code=c&state=${late.url.searchParams.get("state")}`)).status).toBe(400);
    expect((await request("GET", "/v1/imports/oauth/unknown/callback?code=c&state=x")).status).toBe(404);
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM import_oauth_pending WHERE user_id = ?`).bind(userId).first("n")).toBe(0);
    expect(sent).toEqual([]);
  });

  it("sends Notion's credentials as Basic auth in a JSON exchange", async () => {
    const { token } = await signIn();
    const { url } = await start(token, "notion", WEB);
    provider = (u, init) => {
      const headers = new Headers(init?.headers);
      const ok =
        u.href === "https://api.notion.com/v1/oauth/token" &&
        headers.get("Authorization") === `Basic ${btoa("notion-client:notion-secret")}` &&
        headers.get("Content-Type") === "application/json" &&
        JSON.parse(String(init?.body)).code === "n-code" &&
        JSON.parse(String(init?.body)).redirect_uri === "https://api.zimam.test/v1/imports/oauth/notion/callback";
      return ok ? Response.json({ access_token: "ntn_access_token_1", bot_id: "b" }) : new Response("", { status: 400 });
    };
    const res = await request("GET", `/v1/imports/oauth/notion/callback?code=n-code&state=${url.searchParams.get("state")}`);
    const location = new URL(res.headers.get("Location")!);
    expect(location.origin).toBe(WEB);
    const confirmed = await confirm(token, pendingOf(location.href));
    expect(confirmed.status).toBe(202);
    expect(sent).toEqual([expect.objectContaining({ cursor: 0, token: "ntn_access_token_1" })]);
    // No PKCE for Notion: no verifier was kept or sent.
    expect(JSON.parse(String(seen[0]!.init!.body)).code_verifier).toBeUndefined();
  });

  it("runs Trello's fragment flow: the token goes to the client in the fragment and comes back in the confirm", async () => {
    const { token, userId } = await signIn();
    const other = await signIn();
    const { url } = await start(token, "trello");
    expect(url.origin + url.pathname).toBe("https://trello.com/1/authorize");
    expect(url.searchParams.get("key")).toBe(SECRETS.TRELLO_API_KEY);
    expect(url.searchParams.get("scope")).toBe("read");
    expect(url.searchParams.get("callback_method")).toBe("fragment");
    const returnUrl = new URL(url.searchParams.get("return_url")!);
    expect(returnUrl.origin + returnUrl.pathname).toBe("https://api.zimam.test/v1/imports/oauth/trello/callback");
    const state = returnUrl.searchParams.get("state")!;

    // Trello returns to the page with #token=…; the page's script posts only the state.
    const pageRes = await request("GET", `/v1/imports/oauth/trello/callback?state=${state}`);
    expect(pageRes.status).toBe(200);
    const csp = pageRes.headers.get("Content-Security-Policy")!;
    const nonce = csp.match(/'nonce-([^']+)'/)![1]!;
    const html = await pageRes.text();
    expect(html).toContain(`<script nonce="${nonce}">`);
    expect(html).toContain('lang="ar" dir="rtl"');
    expect(TRELLO_PAGE_SCRIPT).toContain("JSON.stringify({ state, granted: !!token })");
    expect(TRELLO_PAGE_SCRIPT).toContain('"#"');

    const trelloToken = "ATTA0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const posted = await request("POST", "/v1/imports/oauth/trello/callback", { json: { state, granted: true } });
    expect(posted.status).toBe(200);
    const answer = await json(posted);
    expect(answer.token).toBe("fragment");
    expect(answer.redirect).toMatch(/^zimam:\/\/import-callback\?pending=[A-Za-z0-9_-]{40,}&source=trello$/);
    const pending = pendingOf(answer.redirect);
    expect(sent).toEqual([]);
    expect(await env.DB.prepare(`SELECT code, code_verifier FROM import_oauth_pending WHERE user_id = ?`).bind(userId).first()).toEqual({ code: null, code_verifier: null });

    // Used: the page's second post is refused.
    expect((await request("POST", "/v1/imports/oauth/trello/callback", { json: { state, granted: true } })).status).toBe(400);

    // Another account cannot take it, even with the token.
    expect((await confirm(other.token, pending, { token: trelloToken })).status).toBe(404);
    // Without the token (or a malformed one) the record stays for a retry.
    expect((await json(await confirm(token, pending))).error.code).toBe("invalid_token");
    expect((await confirm(token, pending, { token: "not a token" })).status).toBe(400);

    const confirmed = await confirm(token, pending, { token: trelloToken });
    expect(confirmed.status).toBe(202);
    expect(sent).toEqual([expect.objectContaining({ cursor: 0, token: `${SECRETS.TRELLO_API_KEY}:${trelloToken}` })]);
    expect(await storedFor(userId)).not.toContain(trelloToken);
    expect((await confirm(token, pending, { token: trelloToken })).status).toBe(410);

    // Refused on Trello's page: no pending record, the client hears «denied».
    await env.DB.prepare(`DELETE FROM import_jobs WHERE user_id = ?`).bind(userId).run();
    const denied = await start(token, "trello", WEB);
    const deniedState = new URL(denied.url.searchParams.get("return_url")!).searchParams.get("state")!;
    const refused = await json(await request("POST", "/v1/imports/oauth/trello/callback", { json: { state: deniedState, granted: false } }));
    expect(refused).toEqual({ redirect: `${WEB}/app/#/import?error=denied` });
  });

  describe("logs", () => {
    const lines: string[] = [];
    beforeEach(() => {
      lines.length = 0;
      for (const level of ["log", "info", "warn", "error", "debug"] as const) {
        vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
          lines.push(args.map((a) => (a instanceof Error ? `${a.name}: ${a.message}` : typeof a === "string" ? a : JSON.stringify(a))).join(" "));
        });
      }
    });
    afterEach(() => vi.restoreAllMocks());

    it("write no code or token, through a confirm, a failed exchange and a failed enqueue", async () => {
      const { token, userId } = await signIn();
      const codes = ["code-secret-ok-1", "code-secret-bad-2"];

      const ok = await start(token, "google-calendar");
      provider = googleServer(ok.url.searchParams.get("code_challenge")!, "ya29.secret-access");
      const first = await request("GET", `/v1/imports/oauth/google-calendar/callback?code=good-code&state=${ok.url.searchParams.get("state")}`);
      expect((await confirm(token, pendingOf(first.headers.get("Location")!))).status).toBe(202);
      await env.DB.prepare(`DELETE FROM import_jobs WHERE user_id = ?`).bind(userId).run();

      const bad = await start(token, "asana");
      provider = () => new Response("nope code-secret-bad-2", { status: 400 });
      const second = await request("GET", `/v1/imports/oauth/asana/callback?code=${codes[1]}&state=${bad.url.searchParams.get("state")}`);
      expect((await confirm(token, pendingOf(second.headers.get("Location")!))).status).toBe(502);

      const trello = await start(token, "trello");
      const trelloState = new URL(trello.url.searchParams.get("return_url")!).searchParams.get("state")!;
      const posted = await json(await request("POST", "/v1/imports/oauth/trello/callback", { json: { state: trelloState, granted: true } }));
      const trelloToken = "ATTAsecret0123456789abcdef0123456789abcdef0123456789abcdef01234567";
      // The queue refuses the message: the job fails, and the log names the job only.
      const failing = createApp({
        appleKeys: testAppleKeys,
        googleKeys: testGoogleKeys,
        ai: () => fakeAi,
        appleTokens: () => null,
        imports: () => ({ ...importDeps(), enqueue: async () => { throw new Error(`queue down ${trelloToken}`); } }),
      });
      const res = await failing.fetch(
        new Request("https://api.zimam.test/v1/imports/oauth/confirm", {
          method: "POST",
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify({ pending: pendingOf(posted.redirect), token: trelloToken }),
        }),
        { ...env, ...SECRETS },
      );
      expect(res.status).toBe(503);

      expect(lines.length).toBeGreaterThan(0);
      const logged = lines.join("\n");
      for (const secret of ["good-code", ...codes, "ya29.secret-access", trelloToken, "ATTAsecret"]) expect(logged).not.toContain(secret);
      const stored = await storedFor(userId);
      for (const secret of ["good-code", ...codes, "ya29.secret-access", trelloToken]) expect(stored).not.toContain(secret);
    });
  });

  it("refuses to start or confirm while another import runs, and forgets flows with the account", async () => {
    const { token, userId } = await signIn();
    const { url } = await start(token, "asana");
    provider = (u) => (u.pathname === "/-/oauth_token" ? Response.json({ access_token: "asana-token-123" }) : new Response("", { status: 404 }));
    const callback = await request("GET", `/v1/imports/oauth/asana/callback?code=c&state=${url.searchParams.get("state")}`);
    const waiting = await start(token, "notion");
    provider = (u) =>
      u.pathname === "/-/oauth_token" || u.pathname === "/v1/oauth/token"
        ? Response.json({ access_token: "some-token-123" })
        : new Response("", { status: 404 });
    const notion = await request("GET", `/v1/imports/oauth/notion/callback?code=n&state=${waiting.url.searchParams.get("state")}`);
    expect((await confirm(token, pendingOf(callback.headers.get("Location")!))).status).toBe(202);
    expect(sent).toHaveLength(1);
    const busy = await request("GET", "/v1/imports/oauth/notion/start?return=app", { token });
    expect(busy.status).toBe(409);
    // A second confirm waits for the first import: 409, and its record stays for a retry.
    const notionPending = pendingOf(notion.headers.get("Location")!);
    expect((await confirm(token, notionPending)).status).toBe(409);
    expect(sent).toHaveLength(1);

    await env.DB.prepare(`DELETE FROM import_jobs WHERE user_id = ?`).bind(userId).run();
    await start(token, "notion");
    expect((await request("DELETE", "/v1/me", { token })).status).toBeLessThan(300);
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM import_oauth_states WHERE user_id = ?`).bind(userId).first("n")).toBe(0);
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM import_oauth_pending WHERE user_id = ?`).bind(userId).first("n")).toBe(0);
  });
});
