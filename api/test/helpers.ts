import { env } from "cloudflare:workers";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import type { AiProvider, AiRequest, AiResult } from "../src/ai/provider";
import { createApp } from "../src/app";
import { AppleTokenError, type AppleTokens } from "../src/auth/apple-tokens";
import { sha256Hex } from "../src/auth/crypto";

const { publicKey, privateKey } = await generateKeyPair("RS256");
const jwk = { ...(await exportJWK(publicKey)), kid: "test-key", alg: "RS256", use: "sig" };

export const testAppleKeys = createLocalJWKSet({ keys: [jwk] });

const google = await generateKeyPair("RS256");
const googleJwk = { ...(await exportJWK(google.publicKey)), kid: "google-test-key", alg: "RS256", use: "sig" };
export const testGoogleKeys = createLocalJWKSet({ keys: [googleJwk] });

/** The Google client IDs the tests run with (vitest.config.ts sets GOOGLE_CLIENT_IDS to these). */
export const GOOGLE_IOS_CLIENT = "test-ios.apps.googleusercontent.com";
export const GOOGLE_WEB_CLIENT = "test-web.apps.googleusercontent.com";
/** A model provider that answers from a queue and keeps every request it was sent. */
export class FakeAi implements AiProvider {
  readonly name = "fake";
  requests: AiRequest[] = [];
  private answers: ((request: AiRequest) => AiResult | Promise<AiResult>)[] = [];

  /** Queues the JSON the next call returns, or an error it throws. */
  answer(json: unknown, usage = { input: 100, output: 20 }) {
    this.answers.push(() => ({ json, usage }));
  }

  fail(error: Error) {
    this.answers.push(() => {
      throw error;
    });
  }

  reset() {
    this.requests = [];
    this.answers = [];
  }

  async complete(request: AiRequest): Promise<AiResult> {
    this.requests.push(request);
    const next = this.answers.shift();
    if (!next) throw new Error("FakeAi: no answer queued");
    return next(request);
  }
}

export const fakeAi = new FakeAi();

/** Apple's token endpoints: codes map to refresh tokens, and revoked tokens are kept for checking. */
export class FakeAppleTokens implements AppleTokens {
  /** Set to false to act as if the Apple key secrets were missing. */
  configured = true;
  codes = new Map<string, { refreshToken: string; sub: string | null }>();
  exchanged: { code: string; clientId: string }[] = [];
  revoked: { refreshToken: string; clientId: string }[] = [];
  failRevoke = false;

  async exchangeCode(code: string, clientId: string) {
    this.exchanged.push({ code, clientId });
    const grant = this.codes.get(code);
    if (!grant) throw new AppleTokenError("Apple /auth/token failed: invalid_grant");
    this.codes.delete(code);
    return grant;
  }

  async revoke(refreshToken: string, clientId: string) {
    if (this.failRevoke) throw new AppleTokenError("Apple /auth/revoke failed: HTTP 503");
    this.revoked.push({ refreshToken, clientId });
  }

  reset() {
    this.configured = true;
    this.codes.clear();
    this.exchanged = [];
    this.revoked = [];
    this.failRevoke = false;
  }
}

export const fakeApple = new FakeAppleTokens();
export const app = createApp({
  appleKeys: testAppleKeys,
  googleKeys: testGoogleKeys,
  ai: () => fakeAi,
  appleTokens: () => (fakeApple.configured ? fakeApple : null),
});

interface AppleTokenOptions {
  audience?: string;
  issuer?: string;
  email?: string;
  /** Apple sends "true" for every address it gives; pass false to test an unverified claim. */
  emailVerified?: boolean;
  nonce?: string;
  expiresIn?: string;
  key?: CryptoKey;
}

/** Signs an identity token shaped like Apple's. */
export async function appleToken(sub: string, o: AppleTokenOptions = {}) {
  const claims: Record<string, unknown> = {};
  if (o.email) {
    claims.email = o.email;
    claims.email_verified = String(o.emailVerified ?? true);
  }
  if (o.nonce) claims.nonce = await sha256Hex(o.nonce);
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "RS256", kid: "test-key" })
    .setSubject(sub)
    .setIssuer(o.issuer ?? "https://appleid.apple.com")
    .setAudience(o.audience ?? "app.zimam.ios")
    .setIssuedAt()
    .setExpirationTime(o.expiresIn ?? "10m")
    .sign(o.key ?? privateKey);
}

interface GoogleTokenOptions {
  audience?: string;
  issuer?: string;
  email?: string;
  emailVerified?: boolean;
  /** Google Workspace domain claim. */
  hd?: string;
  name?: string;
  nonce?: string;
  expiresIn?: string;
  key?: CryptoKey;
}

/** Signs an ID token shaped like Google's. */
export async function googleToken(sub: string, o: GoogleTokenOptions = {}) {
  const claims: Record<string, unknown> = {};
  if (o.email) {
    claims.email = o.email;
    claims.email_verified = o.emailVerified ?? true;
  }
  if (o.hd) claims.hd = o.hd;
  if (o.name) claims.name = o.name;
  if (o.nonce) claims.nonce = await sha256Hex(o.nonce);
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "RS256", kid: "google-test-key" })
    .setSubject(sub)
    .setIssuer(o.issuer ?? "https://accounts.google.com")
    .setAudience(o.audience ?? GOOGLE_IOS_CLIENT)
    .setIssuedAt()
    .setExpirationTime(o.expiresIn ?? "10m")
    .sign(o.key ?? google.privateKey);
}

export async function call(
  method: string,
  path: string,
  options: { token?: string; body?: unknown; env?: Partial<typeof env> } = {},
) {
  const headers = new Headers();
  if (options.token) headers.set("Authorization", `Bearer ${options.token}`);
  if (options.body !== undefined) headers.set("Content-Type", "application/json");
  const response = await app.fetch(
    new Request(`https://api.zimam.test${path}`, {
      method,
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    }),
    options.env ? { ...env, ...options.env } : env,
  );
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

/** Signs in a fresh Apple user and returns their session token and id. */
export async function signIn(sub = `apple-${crypto.randomUUID()}`, name?: string) {
  const res = await call("POST", "/v1/auth/apple", { body: { identityToken: await appleToken(sub), name } });
  if (res.status !== 200) throw new Error(`sign-in failed: ${JSON.stringify(res.body)}`);
  return { token: res.body.token as string, userId: res.body.user.id as string };
}

export const uuid = () => crypto.randomUUID();

/** Pulls every change after `cursor`. */
export async function pullAll(token: string, cursor = 0) {
  const res = await call("GET", `/v1/sync?cursor=${cursor}`, { token });
  return res.body as { changes: { entity: string; id: string; op: string; data?: Record<string, unknown> }[]; cursor: number; hasMore: boolean };
}

export async function push(token: string, mutations: unknown[]) {
  const res = await call("POST", "/v1/sync", { token, body: { mutations } });
  return res.body.results as { entity: string; id: string; status: string; message?: string }[];
}

/** Adds a member directly, without an invite or the sync catch-up that accepting one queues. */
export async function addMember(projectId: string, userId: string, role: "editor" | "viewer") {
  await env.DB.prepare(`INSERT INTO project_members (project_id, user_id, role, added_at) VALUES (?, ?, ?, ?)`)
    .bind(projectId, userId, role, Date.now())
    .run();
}
