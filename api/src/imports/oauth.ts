import { randomToken, sha256Hex } from "../auth/crypto";
import type { Env } from "../env";
import type { OAuthSourceId } from "./source";
import { trelloCredential } from "./sources/trello";

/**
 * The OAuth flows of the import sources (api/DEVELOPMENT.md, «الاستيراد بإذن OAuth»).
 *
 * 1. The signed-in app asks `GET /v1/imports/oauth/:source/start`. The server makes a random
 *    `state`, keeps only its SHA-256 in D1 (`import_oauth_states`) with the user, the source and
 *    where to return, for 15 minutes, and answers the provider's authorization URL.
 * 2. The user agrees on the provider's page, which returns to
 *    `/v1/imports/oauth/:source/callback?code&state` (public: the state names the user).
 * 3. The callback takes the state (single use) and keeps the code in a pending record
 *    (`import_oauth_pending`, 10 minutes, single use) bound to the state's user and source. It
 *    exchanges nothing and starts nothing: it redirects to the app
 *    (`zimam://import-callback?pending=…`) or the site (`/app/#/import?pending=…`).
 * 4. The signed-in client shows which account will receive the data and, once the user agrees,
 *    sends `POST /v1/imports/oauth/confirm { pending }`. Only the user who started the flow can
 *    confirm (anyone else gets 404). The server then exchanges the code with the client secret
 *    and puts the access token in the job's first queue message (never stored or logged).
 *
 * The confirm step stops login CSRF: someone who starts a flow on their own account and sends the
 * provider's link to another person cannot receive that person's data, because the pending id
 * goes only to the browser that consented, which is signed in as its own user, or not at all.
 *
 * Trello returns its token in the URL fragment: its callback page sends the server only the state,
 * and passes the token on to the client in the fragment (never the query); the client sends it in
 * the confirm's body.
 *
 * PKCE (S256) where the provider supports it: the verifier is derived from the state, so it is
 * stored nowhere until the callback, which keeps it beside the code for the confirm's exchange.
 */

/** How long a started flow can wait for the provider's callback. */
export const STATE_TTL_MS = 15 * 60_000;

/** How long a returned flow waits for the client's confirmation. */
export const PENDING_TTL_MS = 10 * 60_000;

/** The app's callback; ASWebAuthenticationSession listens for this scheme. */
export const APP_RETURN = "zimam://import-callback";

interface CodeProvider {
  flow: "code";
  authorizeUrl: string;
  tokenUrl: string;
  /** Space-separated; null sends none (the app's own setting applies). */
  scope: string | null;
  pkce: boolean;
  /** Client credentials in the token request: in the body, or as HTTP Basic. */
  clientAuth: "body" | "basic";
  /** The token request's body. */
  body: "form" | "json";
  /** Extra authorization parameters. */
  params?: Record<string, string>;
  /** Extra token request fields. */
  tokenParams?: Record<string, string>;
  credentials(env: Env): { clientId?: string; clientSecret?: string };
}

/** Trello authorizes with an API key and returns the token in the URL fragment (see the callback page). */
interface TrelloProvider {
  flow: "trello";
  authorizeUrl: string;
  credentials(env: Env): { apiKey?: string };
}

export type OAuthProvider = CodeProvider | TrelloProvider;

export const PROVIDERS: Record<OAuthSourceId, OAuthProvider> = {
  "google-calendar": {
    flow: "code",
    authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    scope: "https://www.googleapis.com/auth/calendar.readonly",
    pkce: true,
    clientAuth: "body",
    body: "form",
    // No refresh token: the import reads once.
    params: { access_type: "online", include_granted_scopes: "false", prompt: "consent" },
    credentials: (env) => ({
      clientId: env.GOOGLE_WEB_CLIENT_ID?.trim() || undefined,
      clientSecret: env.GOOGLE_CLIENT_SECRET,
    }),
  },
  "microsoft-todo": {
    flow: "code",
    // "common": personal Microsoft accounts (where To Do lives) and work or school ones.
    authorizeUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    tokenUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    scope: "Tasks.Read offline_access",
    pkce: true,
    clientAuth: "body",
    body: "form",
    params: { response_mode: "query", prompt: "select_account" },
    tokenParams: { scope: "Tasks.Read offline_access" },
    credentials: (env) => ({ clientId: env.MS_CLIENT_ID, clientSecret: env.MS_CLIENT_SECRET }),
  },
  notion: {
    flow: "code",
    authorizeUrl: "https://api.notion.com/v1/oauth/authorize",
    tokenUrl: "https://api.notion.com/v1/oauth/token",
    scope: null,
    pkce: false,
    clientAuth: "basic",
    body: "json",
    // The user picks the pages and databases to share on Notion's page.
    params: { owner: "user" },
    credentials: (env) => ({ clientId: env.NOTION_CLIENT_ID, clientSecret: env.NOTION_CLIENT_SECRET }),
  },
  trello: {
    flow: "trello",
    authorizeUrl: "https://trello.com/1/authorize",
    credentials: (env) => ({ apiKey: env.TRELLO_API_KEY }),
  },
  asana: {
    flow: "code",
    authorizeUrl: "https://app.asana.com/-/oauth_authorize",
    tokenUrl: "https://app.asana.com/-/oauth_token",
    // The app's permission setting in Asana's console applies (docs/setup.md).
    scope: null,
    pkce: true,
    clientAuth: "body",
    body: "form",
    credentials: (env) => ({ clientId: env.ASANA_CLIENT_ID, clientSecret: env.ASANA_CLIENT_SECRET }),
  },
  "ticktick-api": {
    flow: "code",
    authorizeUrl: "https://ticktick.com/oauth/authorize",
    tokenUrl: "https://ticktick.com/oauth/token",
    scope: "tasks:read",
    pkce: false,
    clientAuth: "basic",
    body: "form",
    tokenParams: { scope: "tasks:read" },
    credentials: (env) => ({ clientId: env.TICKTICK_CLIENT_ID, clientSecret: env.TICKTICK_CLIENT_SECRET }),
  },
  "todoist-oauth": {
    flow: "code",
    authorizeUrl: "https://todoist.com/oauth/authorize",
    tokenUrl: "https://todoist.com/oauth/access_token",
    scope: "data:read",
    pkce: false,
    clientAuth: "body",
    body: "form",
    credentials: (env) => ({ clientId: env.TODOIST_CLIENT_ID, clientSecret: env.TODOIST_CLIENT_SECRET }),
  },
  clickup: {
    flow: "code",
    authorizeUrl: "https://app.clickup.com/api",
    tokenUrl: "https://api.clickup.com/api/v2/oauth/token",
    // ClickUp has no scopes: the user picks the workspaces on its page.
    scope: null,
    pkce: false,
    clientAuth: "body",
    body: "form",
    credentials: (env) => ({ clientId: env.CLICKUP_CLIENT_ID, clientSecret: env.CLICKUP_CLIENT_SECRET }),
  },
  planner: {
    flow: "code",
    // The same Microsoft Entra app as To Do; Planner lives in work and school accounts.
    authorizeUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    tokenUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    scope: "Tasks.Read",
    pkce: true,
    clientAuth: "body",
    body: "form",
    params: { response_mode: "query", prompt: "select_account" },
    tokenParams: { scope: "Tasks.Read" },
    credentials: (env) => ({ clientId: env.MS_CLIENT_ID, clientSecret: env.MS_CLIENT_SECRET }),
  },
  jira: {
    flow: "code",
    authorizeUrl: "https://auth.atlassian.com/authorize",
    tokenUrl: "https://auth.atlassian.com/oauth/token",
    scope: "read:jira-work",
    pkce: false,
    clientAuth: "body",
    body: "json",
    params: { audience: "api.atlassian.com", prompt: "consent" },
    credentials: (env) => ({ clientId: env.JIRA_CLIENT_ID, clientSecret: env.JIRA_CLIENT_SECRET }),
  },
  linear: {
    flow: "code",
    authorizeUrl: "https://linear.app/oauth/authorize",
    tokenUrl: "https://api.linear.app/oauth/token",
    scope: "read",
    pkce: false,
    clientAuth: "body",
    body: "form",
    credentials: (env) => ({ clientId: env.LINEAR_CLIENT_ID, clientSecret: env.LINEAR_CLIENT_SECRET }),
  },
  monday: {
    flow: "code",
    authorizeUrl: "https://auth.monday.com/oauth2/authorize",
    tokenUrl: "https://auth.monday.com/oauth2/token",
    scope: "boards:read",
    pkce: false,
    clientAuth: "body",
    body: "form",
    credentials: (env) => ({ clientId: env.MONDAY_CLIENT_ID, clientSecret: env.MONDAY_CLIENT_SECRET }),
  },
  "google-tasks-api": {
    flow: "code",
    authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    scope: "https://www.googleapis.com/auth/tasks.readonly",
    pkce: true,
    clientAuth: "body",
    body: "form",
    // The same web client and secret as Google Calendar; no refresh token: the import reads once.
    params: { access_type: "online", include_granted_scopes: "false", prompt: "consent" },
    credentials: (env) => ({
      clientId: env.GOOGLE_WEB_CLIENT_ID?.trim() || undefined,
      clientSecret: env.GOOGLE_CLIENT_SECRET,
    }),
  },
};

export const isOAuthSource = (id: string): id is OAuthSourceId => Object.hasOwn(PROVIDERS, id);

/** Whether the deployment has the source's secrets; without them the source is listed as unavailable. */
export function oauthAvailable(env: Env, source: OAuthSourceId): boolean {
  const provider = PROVIDERS[source];
  if (provider.flow === "trello") return !!provider.credentials(env).apiKey?.trim();
  const { clientId, clientSecret } = provider.credentials(env);
  return !!clientId?.trim() && !!clientSecret?.trim();
}

/** Where the provider returns: this API's own callback for the source. */
export function callbackUrl(requestUrl: string, source: OAuthSourceId): string {
  return `${new URL(requestUrl).origin}/v1/imports/oauth/${source}/callback`;
}

/**
 * Where a client asked to come back: "app", or one of the site's origins (ALLOWED_ORIGINS).
 * Anything else is refused, so the callback never redirects to a place we do not own.
 */
export function parseReturnTarget(value: string | undefined, allowedOrigins: string): string | null {
  if (!value || value === "app") return value === "app" ? "app" : null;
  const origins = allowedOrigins.split(",").map((o) => o.trim()).filter(Boolean);
  return origins.includes(value) ? value : null;
}

/**
 * The URL a returned (or failed) flow sends the user to: `pending` and `source` (for the client's
 * question «استيراد بيانات <المصدر>…؟»), or `error`, in the app's query, or in the site's route,
 * which is itself in the fragment. Trello's token, when there is one, is added to the fragment by
 * its callback page in the browser, never to the query.
 */
export function returnUrl(target: string, result: { pending: string; source: OAuthSourceId } | { error: string }): string {
  const query = new URLSearchParams("pending" in result ? { pending: result.pending, source: result.source } : { error: result.error }).toString();
  return target === "app" ? `${APP_RETURN}?${query}` : `${target}/app/#/import?${query}`;
}

const base64url = (bytes: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** The PKCE verifier of a state: 43 characters, recomputed at the callback rather than stored. */
async function pkceVerifier(state: string): Promise<string> {
  return base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`zimam-pkce\u001f${state}`)));
}

async function pkceChallenge(verifier: string): Promise<string> {
  return base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
}

export interface StateRow {
  state_hash: string;
  user_id: string;
  source: OAuthSourceId;
  return_to: string;
  created_at: number;
  expires_at: number;
}

/**
 * Starts a flow: stores the state's hash and returns the provider's authorization URL.
 * Expired states are swept here, so the table stays small without a cron.
 */
export async function startAuthorization(
  db: D1Database,
  env: Env,
  o: { userId: string; source: OAuthSourceId; returnTo: string; callback: string },
  now = Date.now(),
): Promise<{ url: string; expiresAt: number }> {
  const provider = PROVIDERS[o.source];
  const state = randomToken();
  const expiresAt = now + STATE_TTL_MS;
  await db.batch([
    db.prepare(`DELETE FROM import_oauth_states WHERE expires_at < ?`).bind(now),
    sweepPending(db, now),
    db
      .prepare(`INSERT INTO import_oauth_states (state_hash, user_id, source, return_to, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)`)
      .bind(await sha256Hex(state), o.userId, o.source, o.returnTo, now, expiresAt),
  ]);

  if (provider.flow === "trello") {
    const url = new URL(provider.authorizeUrl);
    url.searchParams.set("key", provider.credentials(env).apiKey!.trim());
    url.searchParams.set("name", "زمام");
    url.searchParams.set("scope", "read");
    url.searchParams.set("expiration", "1day");
    url.searchParams.set("response_type", "token");
    url.searchParams.set("callback_method", "fragment");
    url.searchParams.set("return_url", `${o.callback}?state=${state}`);
    return { url: url.toString(), expiresAt };
  }

  const url = new URL(provider.authorizeUrl);
  url.searchParams.set("client_id", provider.credentials(env).clientId!.trim());
  url.searchParams.set("redirect_uri", o.callback);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("state", state);
  if (provider.scope) url.searchParams.set("scope", provider.scope);
  if (provider.pkce) {
    url.searchParams.set("code_challenge", await pkceChallenge(await pkceVerifier(state)));
    url.searchParams.set("code_challenge_method", "S256");
  }
  for (const [k, v] of Object.entries(provider.params ?? {})) url.searchParams.set(k, v);
  return { url: url.toString(), expiresAt };
}

/** Takes a state for the source, once: a second use, another source or an expired one gives null. */
export async function takeState(db: D1Database, state: string, source: OAuthSourceId, now = Date.now()): Promise<StateRow | null> {
  if (!state || state.length > 200) return null;
  const row = await db
    .prepare(`DELETE FROM import_oauth_states WHERE state_hash = ? RETURNING *`)
    .bind(await sha256Hex(state))
    .first<StateRow>();
  if (!row || row.source !== source || row.expires_at < now) return null;
  return row;
}

// MARK: The pending record between the callback and the confirm

export interface PendingRow {
  pending_hash: string;
  user_id: string;
  source: OAuthSourceId;
  /** The authorization code until the confirm; null for Trello, and once used. */
  code: string | null;
  code_verifier: string | null;
  created_at: number;
  expires_at: number;
  used_at: number | null;
}

/** Deletes used and expired pending records: a used one only answers 410 until its time is up. */
const sweepPending = (db: D1Database, now: number) => db.prepare(`DELETE FROM import_oauth_pending WHERE expires_at < ?`).bind(now);

/**
 * At the callback: keeps what the confirm needs for the state's user and source (the code and its
 * PKCE verifier; nothing for Trello), and returns the random pending id for the client. Only its
 * SHA-256 is stored.
 */
export async function createPending(
  db: D1Database,
  row: Pick<StateRow, "user_id" | "source">,
  o: { state: string; code: string | null },
  now = Date.now(),
): Promise<string> {
  const provider = PROVIDERS[row.source];
  const verifier = provider.flow === "code" && provider.pkce && o.code ? await pkceVerifier(o.state) : null;
  const pending = randomToken();
  await db.batch([
    sweepPending(db, now),
    db
      .prepare(
        `INSERT INTO import_oauth_pending (pending_hash, user_id, source, code, code_verifier, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(await sha256Hex(pending), row.user_id, row.source, o.code, verifier, now, now + PENDING_TTL_MS),
  ]);
  return pending;
}

/**
 * The user's pending record, without taking it. `not_found` when there is none or it is another
 * user's (the two look the same), `gone` when it was used or has expired.
 */
export async function findPending(
  db: D1Database,
  pending: string,
  userId: string,
  now = Date.now(),
): Promise<{ kind: "ok"; row: PendingRow } | { kind: "not_found" } | { kind: "gone" }> {
  if (!pending || pending.length > 200) return { kind: "not_found" };
  const row = await db.prepare(`SELECT * FROM import_oauth_pending WHERE pending_hash = ?`).bind(await sha256Hex(pending)).first<PendingRow>();
  if (!row || row.user_id !== userId) return { kind: "not_found" };
  if (row.used_at !== null || row.expires_at < now) return { kind: "gone" };
  return { kind: "ok", row };
}

/**
 * Takes the record, once: marks it used and clears the code and verifier in the same statement.
 * False when another request took it first or it expired meanwhile.
 */
export async function takePending(db: D1Database, row: PendingRow, now = Date.now()): Promise<boolean> {
  const result = await db
    .prepare(
      `UPDATE import_oauth_pending SET used_at = ?3, code = NULL, code_verifier = NULL
       WHERE pending_hash = ?1 AND user_id = ?2 AND used_at IS NULL AND expires_at >= ?3`,
    )
    .bind(row.pending_hash, row.user_id, now)
    .run();
  return result.meta.changes > 0;
}

/** The token endpoint refused or failed. The message names the source and the HTTP status only. */
export class OAuthExchangeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "OAuthExchangeError";
  }
}

/**
 * Exchanges an authorization code (from the pending record, with its PKCE verifier) for the access
 * token. The refresh token, if any, is dropped.
 */
export async function exchangeCode(
  env: Env,
  fetcher: typeof fetch,
  source: OAuthSourceId,
  o: { code: string; verifier: string | null; callback: string },
): Promise<string> {
  const provider = PROVIDERS[source];
  if (provider.flow !== "code") throw new OAuthExchangeError(`${source}: no code flow`);
  const { clientId, clientSecret } = provider.credentials(env);
  const fields: Record<string, string> = {
    grant_type: "authorization_code",
    code: o.code,
    redirect_uri: o.callback,
    ...(provider.tokenParams ?? {}),
  };
  if (provider.pkce) {
    if (!o.verifier) throw new OAuthExchangeError(`${source}: no PKCE verifier`);
    fields.code_verifier = o.verifier;
  }
  const headers: Record<string, string> = { Accept: "application/json" };
  if (provider.clientAuth === "basic") {
    headers.Authorization = `Basic ${btoa(`${clientId!.trim()}:${clientSecret!.trim()}`)}`;
  } else {
    fields.client_id = clientId!.trim();
    fields.client_secret = clientSecret!.trim();
  }
  let body: string;
  if (provider.body === "json") {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(fields);
  } else {
    headers["Content-Type"] = "application/x-www-form-urlencoded";
    body = new URLSearchParams(fields).toString();
  }
  let response: Response;
  try {
    response = await fetcher(provider.tokenUrl, { method: "POST", headers, body });
  } catch {
    throw new OAuthExchangeError(`${source}: token endpoint unreachable`);
  }
  if (!response.ok) throw new OAuthExchangeError(`${source}: token endpoint HTTP ${response.status}`);
  let token: unknown;
  try {
    token = ((await response.json()) as { access_token?: unknown }).access_token;
  } catch {
    throw new OAuthExchangeError(`${source}: unreadable token response`);
  }
  if (typeof token !== "string" || token.length < 8 || token.length > 4096) throw new OAuthExchangeError(`${source}: no access token`);
  return token;
}

/** Trello's token from the callback page, with the API key it works with (`sources/trello.ts`). */
export function trelloToken(env: Env, token: unknown): string | null {
  if (typeof token !== "string" || !/^[A-Za-z0-9_-]{20,300}$/.test(token)) return null;
  const key = env.TRELLO_API_KEY?.trim();
  return key ? trelloCredential(key, token) : null;
}
