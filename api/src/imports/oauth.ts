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
 * 3. The callback takes the state (single use), exchanges the code with the client secret, puts
 *    the access token in the job's first queue message (never stored or logged), and redirects
 *    to the app (`zimam://import-callback?job=…`) or the site (`/app/#/import?job=…`).
 *
 * PKCE (S256) where the provider supports it: the verifier is derived from the state, so it is
 * stored nowhere and only the request holding the state can present it.
 */

/** How long a started flow can wait for the provider's callback. */
export const STATE_TTL_MS = 15 * 60_000;

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

/** The URL a finished (or failed) flow sends the user to. */
export function returnUrl(target: string, result: { job: string } | { error: string }): string {
  const query = new URLSearchParams("job" in result ? { job: result.job } : { error: result.error }).toString();
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

/** The token endpoint refused or failed. The message names the source and the HTTP status only. */
export class OAuthExchangeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "OAuthExchangeError";
  }
}

/** Exchanges an authorization code for the access token. The refresh token, if any, is dropped. */
export async function exchangeCode(
  env: Env,
  fetcher: typeof fetch,
  source: OAuthSourceId,
  o: { code: string; state: string; callback: string },
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
  if (provider.pkce) fields.code_verifier = await pkceVerifier(o.state);
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
