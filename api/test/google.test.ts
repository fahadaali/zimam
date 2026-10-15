import { createExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { generateKeyPair } from "jose";
import { describe, expect, it } from "vitest";
import { Assistant } from "../src/assistant";
import { ZimamService } from "../src/service";
import {
  appleToken,
  call,
  GOOGLE_WEB_CLIENT,
  googleToken,
  testAppleKeys,
  testGoogleKeys,
  uuid,
} from "./helpers";

const email = () => `person-${uuid()}@example.com`;

async function google(sub: string, options: Parameters<typeof googleToken>[1] = {}, extra: Record<string, unknown> = {}) {
  return call("POST", "/v1/auth/google", { body: { idToken: await googleToken(sub, options), ...extra } });
}

async function apple(sub: string, options: Parameters<typeof appleToken>[1] = {}) {
  return call("POST", "/v1/auth/apple", { body: { identityToken: await appleToken(sub, options) } });
}

const userId = (res: { body: { user: { id: string } } }) => res.body.user.id;

const identities = async (id: string) =>
  (
    await env.DB.prepare(`SELECT provider, subject, email, email_verified FROM identities WHERE user_id = ? ORDER BY provider`)
      .bind(id)
      .all()
  ).results;

describe("Sign in with Google", () => {
  it("creates a user and session from a valid ID token, named from the token", async () => {
    const address = email();
    const res = await google(`g-${uuid()}`, { email: address, name: "نورة" }, { device: "web" });
    expect(res.status).toBe(200);
    expect(res.body.token).toMatch(/^zs_/);
    expect(res.body.user).toMatchObject({ name: "نورة", email: address, settings: { calendar: "hijri" } });

    const me = await call("GET", "/v1/me", { token: res.body.token });
    expect(me.status).toBe(200);
    expect(me.body.id).toBe(userId(res));

    const row = await env.DB.prepare(`SELECT apple_sub FROM users WHERE id = ?`).bind(userId(res)).first<{ apple_sub: string }>();
    expect(row!.apple_sub).toBe(`none:${userId(res)}`);
  });

  it("prefers the name the client sends", async () => {
    const res = await google(`g-${uuid()}`, { name: "Noura" }, { name: "نورة" });
    expect(res.body.user.name).toBe("نورة");
  });

  it("returns the same user on the next sign-in and keeps the first name", async () => {
    const sub = `g-${uuid()}`;
    const first = await google(sub, { name: "سارة" });
    const second = await google(sub, { name: "Sara" });
    expect(userId(second)).toBe(userId(first));
    expect(second.body.user.name).toBe("سارة");
  });

  it("accepts both client IDs and both issuer spellings", async () => {
    expect((await google(`g-${uuid()}`, { audience: GOOGLE_WEB_CLIENT })).status).toBe(200);
    expect((await google(`g-${uuid()}`, { issuer: "accounts.google.com" })).status).toBe(200);
  });

  it.each([
    ["a foreign audience", { audience: "someone-else.apps.googleusercontent.com" }],
    ["a foreign issuer", { issuer: "https://evil.example" }],
    ["Apple's issuer", { issuer: "https://appleid.apple.com" }],
    ["an expired token", { expiresIn: "-1m" }],
  ])("rejects %s", async (_, options) => {
    const res = await google(`g-${uuid()}`, options);
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("invalid_token");
  });

  it("rejects a token signed by another key, including Apple's", async () => {
    const { privateKey } = await generateKeyPair("RS256");
    expect((await google(`g-${uuid()}`, { key: privateKey })).status).toBe(401);
    // An Apple token never passes as a Google one.
    const appleSigned = await appleToken(`a-${uuid()}`, { audience: GOOGLE_WEB_CLIENT });
    expect((await call("POST", "/v1/auth/google", { body: { idToken: appleSigned } })).status).toBe(401);
  });

  it("checks the nonce when the client sends one", async () => {
    const idToken = await googleToken(`g-${uuid()}`, { nonce: "n-123" });
    expect((await call("POST", "/v1/auth/google", { body: { idToken, nonce: "n-123" } })).status).toBe(200);
    expect((await call("POST", "/v1/auth/google", { body: { idToken, nonce: "other" } })).status).toBe(401);
    const without = await googleToken(`g-${uuid()}`);
    expect((await call("POST", "/v1/auth/google", { body: { idToken: without, nonce: "n-123" } })).status).toBe(401);
  });

  it("requires an ID token", async () => {
    expect((await call("POST", "/v1/auth/google", { body: {} })).status).toBe(400);
  });

  it("answers 503 google_unavailable when no client ID is configured", async () => {
    const res = await call("POST", "/v1/auth/google", {
      body: { idToken: await googleToken(`g-${uuid()}`) },
      env: { GOOGLE_CLIENT_IDS: "" },
    });
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe("google_unavailable");
  });
});

describe("Merging Apple and Google accounts by verified email", () => {
  it("joins a Google sign-in to the Apple account with the same verified email", async () => {
    const address = email();
    const appleSub = `a-${uuid()}`;
    const first = await apple(appleSub, { email: address });
    const viaGoogle = await google(`g-${uuid()}`, { email: address.toUpperCase() });
    expect(userId(viaGoogle)).toBe(userId(first));
    expect(viaGoogle.body.user.email).toBe(address);
    // Both keep working afterwards.
    expect(userId(await apple(appleSub))).toBe(userId(first));
    expect((await identities(userId(first))).map((i) => i.provider)).toEqual(["apple", "google"]);
  });

  it("joins an Apple sign-in to the Google account with the same verified email", async () => {
    const address = email();
    const googleSub = `g-${uuid()}`;
    const first = await google(googleSub, { email: address });
    const viaApple = await apple(`a-${uuid()}`, { email: address });
    expect(userId(viaApple)).toBe(userId(first));
    expect(userId(await google(googleSub))).toBe(userId(first));
  });

  it("never merges on an unverified Google email", async () => {
    const address = email();
    const first = await apple(`a-${uuid()}`, { email: address });
    const viaGoogle = await google(`g-${uuid()}`, { email: address, emailVerified: false });
    expect(userId(viaGoogle)).not.toBe(userId(first));
  });

  it("never merges into an account whose matching email is unverified", async () => {
    const address = email();
    const first = await google(`g-${uuid()}`, { email: address, emailVerified: false });
    const viaApple = await apple(`a-${uuid()}`, { email: address });
    expect(userId(viaApple)).not.toBe(userId(first));
  });

  it("never merges on an unverified Apple email", async () => {
    const address = email();
    const first = await google(`g-${uuid()}`, { email: address });
    const viaApple = await apple(`a-${uuid()}`, { email: address, emailVerified: false });
    expect(userId(viaApple)).not.toBe(userId(first));
  });

  it("never merges on an Apple private relay address", async () => {
    const relay = `${uuid()}@privaterelay.appleid.com`;
    const first = await apple(`a-${uuid()}`, { email: relay });
    const viaGoogle = await google(`g-${uuid()}`, { email: relay.toUpperCase() });
    expect(userId(viaGoogle)).not.toBe(userId(first));
  });

  it("does not guess when several accounts share the email", async () => {
    const address = email();
    const one = await google(`g-${uuid()}`, { email: address, emailVerified: false });
    const two = await google(`g-${uuid()}`, { email: address, emailVerified: false });
    await env.DB.prepare(`UPDATE identities SET email_verified = 1 WHERE lower(email) = ?`).bind(address).run();
    const viaApple = await apple(`a-${uuid()}`, { email: address });
    expect([userId(one), userId(two)]).not.toContain(userId(viaApple));
  });

  it("keeps a returning identity on its own account even if its email now matches another", async () => {
    const address = email();
    const googleSub = `g-${uuid()}`;
    const mine = await google(googleSub, { email: `other-${uuid()}@example.com` });
    await apple(`a-${uuid()}`, { email: address });
    expect(userId(await google(googleSub, { email: address }))).toBe(userId(mine));
  });

  it("signs in an Apple user created before identities existed, and links the identity", async () => {
    const id = uuid();
    const sub = `a-legacy-${uuid()}`;
    const now = Date.now();
    await env.DB.prepare(`INSERT INTO users (id, apple_sub, email, name, created_at, updated_at) VALUES (?, ?, NULL, 'قديم', ?, ?)`)
      .bind(id, sub, now, now)
      .run();
    const res = await apple(sub);
    expect(userId(res)).toBe(id);
    expect(res.body.user.name).toBe("قديم");
    expect(await identities(id)).toEqual([{ provider: "apple", subject: sub, email: null, email_verified: 0 }]);
  });
});

describe("Migration 0008", () => {
  it("backfills one verified Apple identity per live user, skipping deleted ones", async () => {
    const backfill = env.TEST_MIGRATIONS.find((m) => m.name.startsWith("0008"))!
      .queries.find((q) => q.includes("INSERT INTO identities"))!;
    const now = Date.now();
    const live = uuid();
    const silent = uuid();
    const gone = uuid();
    const address = email();
    await env.DB.batch([
      env.DB.prepare(`INSERT INTO users (id, apple_sub, email, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`).bind(live, `a-${live}`, address, now, now),
      env.DB.prepare(`INSERT INTO users (id, apple_sub, email, created_at, updated_at) VALUES (?, ?, NULL, ?, ?)`).bind(silent, `a-${silent}`, now, now),
      env.DB.prepare(`INSERT INTO users (id, apple_sub, email, created_at, updated_at) VALUES (?, ?, NULL, ?, ?)`).bind(gone, `deleted:${gone}`, now, now),
    ]);
    // The rows signed in earlier in this file already have identities; the backfill fills the rest.
    await env.DB.prepare(backfill.replace("INSERT INTO identities", "INSERT OR IGNORE INTO identities")).run();

    expect(await identities(live)).toEqual([{ provider: "apple", subject: `a-${live}`, email: address, email_verified: 1 }]);
    expect(await identities(silent)).toEqual([{ provider: "apple", subject: `a-${silent}`, email: null, email_verified: 0 }]);
    expect(await identities(gone)).toEqual([]);
    // A Google sign-in with the backfilled address joins that user.
    expect(userId(await google(`g-${uuid()}`, { email: address }))).toBe(live);
  });
});

describe("Deleting a merged account", () => {
  it("unlinks every identity, so Google and Apple then start fresh accounts", async () => {
    const address = email();
    const appleSub = `a-${uuid()}`;
    const googleSub = `g-${uuid()}`;
    const first = await apple(appleSub, { email: address });
    expect(userId(await google(googleSub, { email: address }))).toBe(userId(first));

    expect((await call("DELETE", "/v1/me", { token: first.body.token })).status).toBe(204);
    expect(await identities(userId(first))).toEqual([]);

    const again = await google(googleSub, { email: address });
    expect(again.status).toBe(200);
    expect(userId(again)).not.toBe(userId(first));
    expect(again.body.user.email).toBe(address);
    const tasks = await call("GET", "/v1/tasks", { token: again.body.token });
    expect(tasks.status).toBe(200);
  });
});

describe("Assistant and ZimamService sign-in with Google", () => {
  const assistant = new Assistant(env, { apple: testAppleKeys, google: testGoogleKeys });

  it("links the same account as the app and checks the consent page's nonce", async () => {
    const sub = `g-${uuid()}`;
    const app = await google(sub, { name: "ريم" });
    const idToken = await googleToken(sub, { audience: GOOGLE_WEB_CLIENT, nonce: "handle-1" });
    const signedIn = await assistant.signInWithGoogle(idToken, "handle-1");
    expect(signedIn).toEqual({ ok: true, value: { userId: userId(app), name: "ريم" } });
    const replay = await assistant.signInWithGoogle(idToken, "another-handle");
    expect(replay).toMatchObject({ ok: false, error: { code: "invalid_token" } });
  });

  it("goes through ZimamService for the MCP worker", async () => {
    const keys = ZimamService.keys;
    ZimamService.keys = { apple: testAppleKeys, google: testGoogleKeys };
    try {
      const service = new ZimamService(createExecutionContext(), env);
      const sub = `g-${uuid()}`;
      const idToken = await googleToken(sub, { audience: GOOGLE_WEB_CLIENT, nonce: "handle-2", name: "هند" });
      const result = await service.signInWithGoogle(idToken, "handle-2");
      expect(result.ok).toBe(true);
      if (!result.ok) return;
      expect(result.value.name).toBe("هند");
      expect(userId(await google(sub))).toBe(result.value.userId);

      const off = new ZimamService(createExecutionContext(), { ...env, GOOGLE_CLIENT_IDS: "" });
      expect(await off.signInWithGoogle(idToken, "handle-2")).toMatchObject({ ok: false, error: { code: "google_unavailable" } });
    } finally {
      ZimamService.keys = keys;
    }
  });
});
