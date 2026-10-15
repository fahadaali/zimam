import { createExecutionContext, createMessageBatch, getQueueResult } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { sha256Hex } from "../src/auth/crypto";
import type { ImportDeps, ImportMessage } from "../src/imports/jobs";
import { STATE_TTL_MS } from "../src/imports/oauth";
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

  it("needs «زمام الاحترافية» when plans are enforced, at the start and at the callback", async () => {
    const { token } = await signIn();
    const res = await request("GET", "/v1/imports/oauth/asana/start?return=app", { token, env: { SUBSCRIPTIONS_ENFORCED: "true" } });
    expect(res.status).toBe(403);
    expect((await json(res)).error.code).toBe("pro_required");

    // Started while free to use, finished after enforcement began: no job.
    const { url } = await start(token, "asana");
    provider = (u) => (u.pathname === "/-/oauth_token" ? Response.json({ access_token: "asana-token-123" }) : new Response("", { status: 404 }));
    const callback = await request("GET", `/v1/imports/oauth/asana/callback?code=c&state=${url.searchParams.get("state")}`, { env: { SUBSCRIPTIONS_ENFORCED: "true" } });
    expect(callback.headers.get("Location")).toBe("zimam://import-callback?error=pro_required");
    expect(sent).toEqual([]);
  });

  it("exchanges the code, queues the import with the token, and returns to the app with the job", async () => {
    const { token, userId } = await signIn();
    const { url } = await start(token, "google-calendar");
    const state = url.searchParams.get("state")!;
    provider = googleServer(url.searchParams.get("code_challenge")!);

    // Public: no session on the way back from Google.
    const res = await request("GET", `/v1/imports/oauth/google-calendar/callback?code=good-code&state=${state}&scope=x`);
    expect(res.status).toBe(302);
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    const location = new URL(res.headers.get("Location")!);
    expect(`${location.protocol}//${location.host}`).toBe("zimam://import-callback");
    const jobId = location.searchParams.get("job")!;
    expect(sent).toEqual([{ jobId, cursor: 0, token: "ya29.calendar-token" }]);

    // The token is in no table: not the job, not the (deleted) state.
    const job = await env.DB.prepare(`SELECT * FROM import_jobs WHERE id = ?`).bind(jobId).first();
    expect(job).toMatchObject({ user_id: userId, source: "google-calendar", status: "queued" });
    expect(JSON.stringify(job)).not.toContain("ya29");
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM import_oauth_states WHERE user_id = ?`).bind(userId).first("n")).toBe(0);

    await deliverAll();
    const done = await json(await request("GET", `/v1/imports/${jobId}`, { token }));
    expect(done.job).toMatchObject({ status: "done", source: "google-calendar", counts: { created: 3, failed: 0 } });
    const task = await env.DB.prepare(`SELECT * FROM tasks WHERE owner_id = ? AND title = ?`).bind(userId, "موعد الطبيب").first();
    expect(task).toMatchObject({ due_date: "2026-10-20", due_time: "08:00", start_date: null });
    // A multi-day event keeps its span: the start day reaches the Mutator.
    const span = await env.DB.prepare(`SELECT * FROM tasks WHERE owner_id = ? AND title = ?`).bind(userId, "مؤتمر").first();
    expect(span).toMatchObject({ start_date: "2026-11-02", due_date: "2026-11-04", due_time: null });

    // The state is single use.
    const again = await request("GET", `/v1/imports/oauth/google-calendar/callback?code=good-code&state=${state}`);
    expect(again.status).toBe(400);
    expect(again.headers.get("Content-Type")).toMatch(/^text\/html/);
    expect(await again.text()).toContain("انتهت صلاحية طلب الربط");
  });

  it("returns to the site, and reports a refusal or a failed exchange there", async () => {
    const { token } = await signIn();
    const denied = await start(token, "microsoft-todo", WEB);
    const res = await request("GET", `/v1/imports/oauth/microsoft-todo/callback?error=access_denied&error_description=x&state=${denied.url.searchParams.get("state")}`);
    expect(res.headers.get("Location")).toBe(`${WEB}/app/#/import?error=denied`);

    const failing = await start(token, "microsoft-todo", WEB);
    provider = () => Response.json({ error: "invalid_grant" }, { status: 400 });
    const res2 = await request("GET", `/v1/imports/oauth/microsoft-todo/callback?code=bad&state=${failing.url.searchParams.get("state")}`);
    expect(res2.headers.get("Location")).toBe(`${WEB}/app/#/import?error=exchange_failed`);
    // Basic auth for Notion and TickTick, body credentials for Microsoft.
    const body = new URLSearchParams(String(seen.at(-1)!.init!.body));
    expect(body.get("client_secret")).toBe("ms-secret");
    expect(body.get("code_verifier")).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(sent).toEqual([]);
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
        JSON.parse(String(init?.body)).code === "n-code";
      return ok ? Response.json({ access_token: "ntn_access_token_1", bot_id: "b" }) : new Response("", { status: 400 });
    };
    const res = await request("GET", `/v1/imports/oauth/notion/callback?code=n-code&state=${url.searchParams.get("state")}`);
    const location = new URL(res.headers.get("Location")!);
    expect(location.origin).toBe(WEB);
    expect(location.hash).toMatch(/^#\/import\?job=[0-9a-f-]{36}$/);
    expect(sent).toEqual([expect.objectContaining({ cursor: 0, token: "ntn_access_token_1" })]);
  });

  it("runs Trello's fragment flow through its callback page", async () => {
    const { token } = await signIn();
    const { url } = await start(token, "trello");
    expect(url.origin + url.pathname).toBe("https://trello.com/1/authorize");
    expect(url.searchParams.get("key")).toBe(SECRETS.TRELLO_API_KEY);
    expect(url.searchParams.get("scope")).toBe("read");
    expect(url.searchParams.get("callback_method")).toBe("fragment");
    const returnUrl = new URL(url.searchParams.get("return_url")!);
    expect(returnUrl.origin + returnUrl.pathname).toBe("https://api.zimam.test/v1/imports/oauth/trello/callback");
    const state = returnUrl.searchParams.get("state")!;

    // Trello returns to the page with #token=…; the page's script posts it back.
    const pageRes = await request("GET", `/v1/imports/oauth/trello/callback?state=${state}`);
    expect(pageRes.status).toBe(200);
    const csp = pageRes.headers.get("Content-Security-Policy")!;
    const nonce = csp.match(/'nonce-([^']+)'/)![1]!;
    const html = await pageRes.text();
    expect(html).toContain(`<script nonce="${nonce}">`);
    expect(html).toContain('lang="ar" dir="rtl"');

    const trelloToken = "ATTA0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const posted = await request("POST", "/v1/imports/oauth/trello/callback", { json: { state, token: trelloToken } });
    expect(posted.status).toBe(200);
    const { redirect } = await json(posted);
    expect(redirect).toMatch(/^zimam:\/\/import-callback\?job=[0-9a-f-]{36}$/);
    expect(sent).toEqual([expect.objectContaining({ token: `${SECRETS.TRELLO_API_KEY}:${trelloToken}` })]);

    // Used: the page's second post is refused.
    const again = await request("POST", "/v1/imports/oauth/trello/callback", { json: { state, token: trelloToken } });
    expect(again.status).toBe(400);
  });

  it("refuses to start while another import runs, and forgets states with the account", async () => {
    const { token, userId } = await signIn();
    const { url } = await start(token, "asana");
    provider = (u) => (u.pathname === "/-/oauth_token" ? Response.json({ access_token: "asana-token-123" }) : new Response("", { status: 404 }));
    await request("GET", `/v1/imports/oauth/asana/callback?code=c&state=${url.searchParams.get("state")}`);
    expect(sent).toHaveLength(1);
    const busy = await request("GET", "/v1/imports/oauth/notion/start?return=app", { token });
    expect(busy.status).toBe(409);

    await env.DB.prepare(`DELETE FROM import_jobs WHERE user_id = ?`).bind(userId).run();
    await start(token, "notion");
    expect((await request("DELETE", "/v1/me", { token })).status).toBeLessThan(300);
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM import_oauth_states WHERE user_id = ?`).bind(userId).first("n")).toBe(0);
  });
});
