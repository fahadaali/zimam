import { createExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { decodeProtectedHeader, exportPKCS8, generateKeyPair, jwtVerify } from "jose";
import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import type { Env } from "../src/env";
import type { ImportMessage } from "../src/imports/jobs";
import { ZimamService } from "../src/service";
import {
  type AppStore,
  AppStoreClient,
  AppStoreError,
  type AppStoreEnvironment,
  type AppStoreRenewal,
  type AppStoreTransaction,
  appStoreFromEnv,
} from "../src/subscriptions/appstore";
import { appleToken, fakeAi, testAppleKeys, testGoogleKeys, uuid } from "./helpers";

// MARK: Fakes

/** Apple's transactions and renewal states by environment, and every lookup the server made. */
class FakeAppStore implements AppStore {
  configured = true;
  failing = false;
  failingRenewals = false;
  transactions = new Map<string, { environment: AppStoreEnvironment; transaction: AppStoreTransaction }>();
  renewals = new Map<string, { environment: AppStoreEnvironment; renewal: AppStoreRenewal }>();
  lookups: { id: string; environment: AppStoreEnvironment }[] = [];
  renewalLookups: { id: string; environment: AppStoreEnvironment }[] = [];

  put(transaction: AppStoreTransaction, environment: AppStoreEnvironment = "production") {
    this.transactions.set(transaction.transactionId, { environment, transaction });
  }

  putRenewal(renewal: AppStoreRenewal, environment: AppStoreEnvironment = "production") {
    this.renewals.set(renewal.originalTransactionId, { environment, renewal });
  }

  async getTransaction(id: string, environment: AppStoreEnvironment) {
    this.lookups.push({ id, environment });
    if (this.failing) throw new AppStoreError("App Store production failed: HTTP 500");
    const found = this.transactions.get(id);
    return found && found.environment === environment ? found.transaction : null;
  }

  async getRenewal(id: string, environment: AppStoreEnvironment) {
    this.renewalLookups.push({ id, environment });
    if (this.failingRenewals) throw new AppStoreError("App Store production failed: HTTP 500");
    const found = this.renewals.get(id);
    return found && found.environment === environment ? found.renewal : null;
  }

  reset() {
    this.configured = true;
    this.failing = false;
    this.failingRenewals = false;
    this.transactions.clear();
    this.renewals.clear();
    this.lookups = [];
    this.renewalLookups = [];
  }
}

const store = new FakeAppStore();
let enqueued: ImportMessage[] = [];

const app = createApp({
  appleKeys: testAppleKeys,
  googleKeys: testGoogleKeys,
  ai: () => fakeAi,
  appleTokens: () => null,
  appStore: () => (store.configured ? store : null),
  imports: () => ({
    enqueue: async (message) => {
      enqueued.push(message);
    },
    files: env.IMPORT_FILES,
    fetch: async () => new Response("not stubbed", { status: 500 }),
  }),
});

beforeEach(() => {
  store.reset();
  fakeAi.reset();
  enqueued = [];
});

// MARK: Helpers

const ENFORCED = { SUBSCRIPTIONS_ENFORCED: "true" };
const DAY = 86_400_000;
const MONTHLY = "app.zimam.ios.pro.monthly";
const YEARLY = "app.zimam.ios.pro.yearly";

async function request(method: string, path: string, o: { token?: string; body?: unknown; env?: Partial<Env> } = {}) {
  const headers = new Headers();
  if (o.token) headers.set("Authorization", `Bearer ${o.token}`);
  if (o.body !== undefined) headers.set("Content-Type", "application/json");
  const response = await app.fetch(
    new Request(`https://api.zimam.test${path}`, {
      method,
      headers,
      body: o.body === undefined ? undefined : JSON.stringify(o.body),
    }),
    o.env ? { ...env, ...o.env } : env,
  );
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

async function signInUser(email?: string) {
  const res = await request("POST", "/v1/auth/apple", {
    body: { identityToken: await appleToken(`apple-${uuid()}`, email ? { email } : {}) },
  });
  expect(res.status).toBe(200);
  return { token: res.body.token as string, userId: res.body.user.id as string };
}

let nextId = 2_000_000_000_000;
const transactionId = () => String(nextId++);

/** A transaction as Apple returns it, for `userId`, a month from now by default. */
function transaction(userId: string | undefined, o: Partial<AppStoreTransaction> = {}): AppStoreTransaction {
  const id = o.transactionId ?? transactionId();
  return {
    transactionId: id,
    originalTransactionId: id,
    bundleId: "app.zimam.ios",
    productId: MONTHLY,
    purchaseDate: Date.now() - DAY,
    expiresDate: Date.now() + 30 * DAY,
    appAccountToken: userId,
    environment: "Production",
    type: "Auto-Renewable Subscription",
    ...o,
  };
}

const purchase = (token: string, id: string, extra: Record<string, unknown> = {}) =>
  request("POST", "/v1/subscriptions/apple", { token, body: { transactionId: id, ...extra } });

/** A compact JWS as Apple sends it; the server only decodes these. */
function jws(payload: unknown) {
  const part = (value: unknown) => btoa(JSON.stringify(value)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${part({ alg: "ES256", x5c: [] })}.${part(payload)}.c2lnbmF0dXJl`;
}

function notify(signedTransaction: unknown, o: { type?: string; environment?: string; bundleId?: string } = {}) {
  const signedPayload = jws({
    notificationType: o.type ?? "DID_RENEW",
    notificationUUID: uuid(),
    data: {
      bundleId: o.bundleId ?? "app.zimam.ios",
      environment: o.environment ?? "Production",
      signedTransactionInfo: signedTransaction === undefined ? undefined : jws(signedTransaction),
    },
  });
  return request("POST", "/v1/subscriptions/apple/notifications", { body: { signedPayload } });
}

const rows = (userId: string) =>
  env.DB.prepare(`SELECT * FROM entitlements WHERE user_id = ? ORDER BY original_transaction_id`)
    .bind(userId)
    .all<Record<string, unknown>>()
    .then((r) => r.results);

async function subscribe(user: { token: string; userId: string }, o: Partial<AppStoreTransaction> = {}) {
  const tx = transaction(user.userId, o);
  store.put(tx);
  const res = await purchase(user.token, tx.transactionId);
  expect(res.status).toBe(200);
  return tx;
}

// MARK: Purchases

describe("POST /v1/subscriptions/apple", () => {
  it("verifies the transaction with Apple and makes the user pro", async () => {
    const user = await signInUser();
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body).toEqual({
      plan: "free",
      expiresAt: null,
      productId: null,
      source: null,
      environment: null,
      enforced: false,
    });

    const tx = transaction(user.userId, { productId: YEARLY });
    store.put(tx, "sandbox");
    const res = await purchase(user.token, tx.transactionId);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      plan: "pro",
      expiresAt: tx.expiresDate,
      productId: YEARLY,
      source: "apple",
      environment: "sandbox",
      enforced: false,
    });
    // Production first, then the sandbox (TestFlight, App Review), as Apple recommends.
    expect(store.lookups).toEqual([
      { id: tx.transactionId, environment: "production" },
      { id: tx.transactionId, environment: "sandbox" },
    ]);
    expect(await rows(user.userId)).toMatchObject([
      { original_transaction_id: tx.transactionId, product_id: YEARLY, environment: "sandbox", status: "active", revoked_at: null },
    ]);
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body.plan).toBe("pro");
  });

  it("asks the environment the app names first", async () => {
    const user = await signInUser();
    const tx = transaction(user.userId);
    store.put(tx, "sandbox");
    expect((await purchase(user.token, tx.transactionId, { environment: "sandbox" })).status).toBe(200);
    expect(store.lookups).toEqual([{ id: tx.transactionId, environment: "sandbox" }]);
  });

  it("refuses another app's transaction, an unknown product and another account's purchase", async () => {
    const user = await signInUser();
    const other = await signInUser();
    const cases: [AppStoreTransaction, number, string][] = [
      [transaction(user.userId, { bundleId: "com.example.other" }), 400, "wrong_bundle"],
      [transaction(user.userId, { productId: "app.zimam.ios.coins" }), 400, "unknown_product"],
      [transaction(other.userId), 403, "account_mismatch"],
      [transaction(undefined), 403, "account_mismatch"],
      [transaction("not-a-uuid"), 403, "account_mismatch"],
    ];
    for (const [tx, status, code] of cases) {
      store.put(tx);
      const res = await purchase(user.token, tx.transactionId);
      expect([res.status, res.body.error.code]).toEqual([status, code]);
    }
    expect(await rows(user.userId)).toEqual([]);
    expect(await rows(other.userId)).toEqual([]);
  });

  it("saves an expired or refunded subscription without making the user pro", async () => {
    const user = await signInUser();
    const expired = transaction(user.userId, { purchaseDate: Date.now() - 40 * DAY, expiresDate: Date.now() - 10 * DAY });
    store.put(expired);
    const res = await purchase(user.token, expired.transactionId);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ plan: "free", expiresAt: null });
    expect(await rows(user.userId)).toMatchObject([{ status: "expired" }]);

    const refunded = transaction(user.userId, { revocationDate: Date.now() - 1000, revocationReason: 0 });
    store.put(refunded);
    expect((await purchase(user.token, refunded.transactionId)).body.plan).toBe("free");
    expect((await rows(user.userId)).map((r) => r.status).sort()).toEqual(["expired", "revoked"]);
  });

  it("keeps the newest renewal when an older transaction is restored", async () => {
    const user = await signInUser();
    const first = transaction(user.userId, { purchaseDate: Date.now() - 35 * DAY, expiresDate: Date.now() - 5 * DAY });
    const renewal = transaction(user.userId, {
      originalTransactionId: first.transactionId,
      purchaseDate: Date.now() - 5 * DAY,
      expiresDate: Date.now() + 25 * DAY,
    });
    store.put(first);
    store.put(renewal);
    expect((await purchase(user.token, renewal.transactionId)).body.plan).toBe("pro");
    expect((await purchase(user.token, first.transactionId)).body).toMatchObject({ plan: "pro", expiresAt: renewal.expiresDate });
    expect(await rows(user.userId)).toMatchObject([{ transaction_id: renewal.transactionId, status: "active" }]);
  });

  it("does not move a subscription linked to another account", async () => {
    const owner = await signInUser();
    const tx = await subscribe(owner);
    const other = await signInUser();
    const res = await purchase(other.token, tx.transactionId);
    expect([res.status, res.body.error.code]).toEqual([409, "already_linked"]);
    expect((await rows(owner.userId)).length).toBe(1);
  });

  it("restores a running subscription into a new account after the old one was deleted", async () => {
    const old = await signInUser();
    const tx = await subscribe(old);
    expect((await request("DELETE", "/v1/me", { token: old.token })).status).toBe(204);
    expect(await rows(old.userId)).toEqual([]);

    const fresh = await signInUser();
    const res = await purchase(fresh.token, tx.transactionId);
    expect(res.status).toBe(200);
    expect(res.body.plan).toBe("pro");
    expect((await rows(fresh.userId)).length).toBe(1);
  });

  it("answers 404 for a transaction Apple does not know, and 503 without Apple", async () => {
    const user = await signInUser();
    const missing = await purchase(user.token, "123456789");
    expect([missing.status, missing.body.error.code]).toEqual([404, "transaction_not_found"]);

    store.failing = true;
    const failing = await purchase(user.token, "123456789");
    expect([failing.status, failing.body.error.code]).toEqual([503, "subscriptions_unavailable"]);

    store.reset();
    store.configured = false;
    const unconfigured = await purchase(user.token, "123456789");
    expect([unconfigured.status, unconfigured.body.error.code]).toEqual([503, "subscriptions_unavailable"]);

    expect((await purchase(user.token, "not-a-number")).status).toBe(400);
    expect((await request("POST", "/v1/subscriptions/apple", { body: { transactionId: "1" } })).status).toBe(401);
    expect((await request("GET", "/v1/subscriptions")).status).toBe(401);
  });
});

// MARK: Notifications

describe("POST /v1/subscriptions/apple/notifications", () => {
  it("re-fetches the transaction from Apple instead of trusting the notification", async () => {
    const user = await signInUser();
    const tx = await subscribe(user);
    // Apple now says it was refunded; the notification claims a long, valid subscription.
    store.put({ ...tx, revocationDate: Date.now() - 1000, revocationReason: 1 });
    store.lookups = [];
    const res = await notify({ ...tx, expiresDate: Date.now() + 365 * DAY }, { type: "REFUND" });
    expect(res.status).toBe(200);
    expect(store.lookups).toEqual([{ id: tx.transactionId, environment: "production" }]);
    expect(await rows(user.userId)).toMatchObject([{ status: "revoked" }]);
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body.plan).toBe("free");
  });

  it("applies renewals and expiry, asking the notification's environment first", async () => {
    const user = await signInUser();
    const tx = transaction(user.userId, { environment: "Sandbox" });
    store.put(tx, "sandbox");
    expect((await purchase(user.token, tx.transactionId)).status).toBe(200);

    const renewal = transaction(user.userId, {
      originalTransactionId: tx.transactionId,
      productId: YEARLY,
      purchaseDate: Date.now(),
      expiresDate: Date.now() + 365 * DAY,
    });
    store.put(renewal, "sandbox");
    store.lookups = [];
    // Only the id is read from the notification.
    expect((await notify({ transactionId: renewal.transactionId }, { environment: "Sandbox" })).status).toBe(200);
    expect(store.lookups).toEqual([{ id: renewal.transactionId, environment: "sandbox" }]);
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body).toMatchObject({
      plan: "pro",
      productId: YEARLY,
      expiresAt: renewal.expiresDate,
    });

    store.put({ ...renewal, expiresDate: Date.now() - 1000 }, "sandbox");
    expect((await notify({ transactionId: renewal.transactionId }, { type: "EXPIRED", environment: "Sandbox" })).status).toBe(200);
    expect(await rows(user.userId)).toMatchObject([{ status: "expired" }]);
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body.plan).toBe("free");
  });

  it("links a first notification by appAccountToken, and ignores unknown accounts and other apps", async () => {
    const user = await signInUser();
    const tx = transaction(user.userId);
    store.put(tx);
    expect((await notify({ transactionId: tx.transactionId }, { type: "SUBSCRIBED" })).status).toBe(200);
    expect((await rows(user.userId)).length).toBe(1);

    const stranger = transaction(uuid());
    store.put(stranger);
    expect((await notify({ transactionId: stranger.transactionId })).status).toBe(200);
    const other = transaction(user.userId);
    store.put(other);
    store.lookups = [];
    expect((await notify({ transactionId: other.transactionId }, { bundleId: "com.example.other" })).status).toBe(200);
    expect(store.lookups).toEqual([]);
    expect((await rows(user.userId)).length).toBe(1);
    const count = await env.DB.prepare(`SELECT COUNT(*) AS n FROM entitlements WHERE original_transaction_id = ?`)
      .bind(stranger.transactionId)
      .first<{ n: number }>();
    expect(count?.n).toBe(0);
  });

  it("accepts TEST notifications, refuses bad bodies, and asks Apple to retry when it cannot verify", async () => {
    expect((await notify(undefined, { type: "TEST" })).status).toBe(200);
    expect((await request("POST", "/v1/subscriptions/apple/notifications", { body: { signedPayload: "nope" } })).status).toBe(400);
    expect((await request("POST", "/v1/subscriptions/apple/notifications", { body: {} })).status).toBe(400);
    store.configured = false;
    expect((await notify({ transactionId: "42" })).status).toBe(503);
    store.configured = true;
    store.failing = true;
    expect((await notify({ transactionId: "42" })).status).toBe(503);
  });
});

// MARK: Billing grace period

describe("Billing grace period", () => {
  /** Apple's renewal state while it retries a failed payment, in the grace period until `graceEnd`. */
  const inGrace = (tx: AppStoreTransaction, graceEnd: number): AppStoreRenewal => ({
    originalTransactionId: tx.originalTransactionId,
    status: 4,
    gracePeriodExpiresDate: graceEnd,
    isInBillingRetryPeriod: true,
    expirationIntent: 2,
    autoRenewStatus: 1,
  });

  it("keeps the user pro until the grace period ends after a failed renewal, then free", async () => {
    const user = await signInUser();
    const tx = await subscribe(user);
    expect(store.renewalLookups).toEqual([]);

    // The renewal failed: the transaction has expired, and Apple is retrying within the grace period.
    const expired = { ...tx, expiresDate: Date.now() - 1000 };
    const graceEnd = Date.now() + 6 * DAY;
    store.put(expired);
    store.putRenewal(inGrace(tx, graceEnd));
    expect((await notify({ transactionId: tx.transactionId }, { type: "DID_FAIL_TO_RENEW" })).status).toBe(200);
    expect(store.renewalLookups).toEqual([{ id: tx.originalTransactionId, environment: "production" }]);
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body).toMatchObject({ plan: "pro", expiresAt: graceEnd });
    expect(await rows(user.userId)).toMatchObject([
      { status: "active", expires_at: expired.expiresDate, grace_expires_at: graceEnd, billing_retry: 1, expiration_intent: 2 },
    ]);
    expect((await request("GET", "/v1/subscriptions", { token: user.token, env: ENFORCED })).body).toMatchObject({ plan: "pro", enforced: true });

    // The grace period ended without a payment: Apple may keep retrying, but pro stops.
    store.putRenewal({ ...inGrace(tx, Date.now() - 1000), status: 3 });
    expect((await notify({ transactionId: tx.transactionId }, { type: "GRACE_PERIOD_EXPIRED" })).status).toBe(200);
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body.plan).toBe("free");
    expect(await rows(user.userId)).toMatchObject([{ status: "expired", billing_retry: 1 }]);

    // The payment went through at last: the renewal clears the grace period without asking again.
    const renewal = transaction(user.userId, { originalTransactionId: tx.transactionId, purchaseDate: Date.now(), expiresDate: Date.now() + 30 * DAY });
    store.put(renewal);
    store.renewalLookups = [];
    expect((await notify({ transactionId: renewal.transactionId }, { type: "DID_RENEW" })).status).toBe(200);
    expect(store.renewalLookups).toEqual([]);
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body).toMatchObject({ plan: "pro", expiresAt: renewal.expiresDate });
    expect(await rows(user.userId)).toMatchObject([
      { transaction_id: renewal.transactionId, status: "active", grace_expires_at: null, billing_retry: 0, expiration_intent: null },
    ]);
  });

  it("reads the renewal state for an expired transaction the app sends, in its environment", async () => {
    const user = await signInUser();
    const tx = transaction(user.userId, { purchaseDate: Date.now() - 31 * DAY, expiresDate: Date.now() - DAY });
    const graceEnd = Date.now() + 2 * DAY;
    store.put(tx, "sandbox");
    store.putRenewal(inGrace(tx, graceEnd), "sandbox");
    const res = await purchase(user.token, tx.transactionId, { environment: "sandbox" });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ plan: "pro", expiresAt: graceEnd, environment: "sandbox" });
    expect(store.renewalLookups).toEqual([{ id: tx.originalTransactionId, environment: "sandbox" }]);

    // Retrying without a grace period (or a lapsed subscription Apple no longer retries) is not pro.
    const lapsed = transaction(user.userId, { purchaseDate: Date.now() - 40 * DAY, expiresDate: Date.now() - 10 * DAY });
    store.put(lapsed);
    store.putRenewal({ originalTransactionId: lapsed.originalTransactionId, status: 3, isInBillingRetryPeriod: true, gracePeriodExpiresDate: undefined });
    expect((await purchase(user.token, lapsed.transactionId)).status).toBe(200);
    const cancelled = transaction(user.userId, { purchaseDate: Date.now() - 40 * DAY, expiresDate: Date.now() - 10 * DAY });
    store.put(cancelled);
    store.putRenewal({ originalTransactionId: cancelled.originalTransactionId, status: 2, isInBillingRetryPeriod: false, gracePeriodExpiresDate: Date.now() + DAY, expirationIntent: 1 });
    expect((await purchase(user.token, cancelled.transactionId)).status).toBe(200);
    const byId = Object.fromEntries((await rows(user.userId)).map((r) => [r.original_transaction_id, r]));
    expect(byId[lapsed.transactionId]).toMatchObject({ status: "expired", grace_expires_at: null, billing_retry: 1 });
    expect(byId[cancelled.transactionId]).toMatchObject({ status: "expired", grace_expires_at: null, billing_retry: 0, expiration_intent: 1 });
    // Only the first subscription, still in its grace period, makes the user pro.
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body).toMatchObject({ plan: "pro", expiresAt: graceEnd });
  });

  it("never reads it for an active or refunded transaction, and ignores a grace period after a refund", async () => {
    const user = await signInUser();
    const tx = await subscribe(user);
    store.putRenewal(inGrace(tx, Date.now() + 5 * DAY));
    store.put({ ...tx, expiresDate: Date.now() - 1000, revocationDate: Date.now() - 1000, revocationReason: 0 });
    expect((await notify({ transactionId: tx.transactionId }, { type: "REFUND" })).status).toBe(200);
    expect(store.renewalLookups).toEqual([]);
    expect((await request("GET", "/v1/subscriptions", { token: user.token })).body.plan).toBe("free");
    expect(await rows(user.userId)).toMatchObject([{ status: "revoked", grace_expires_at: null }]);
  });

  it("asks to be retried when Apple cannot give the renewal state", async () => {
    const user = await signInUser();
    const tx = await subscribe(user);
    store.put({ ...tx, expiresDate: Date.now() - 1000 });
    store.failingRenewals = true;
    expect((await notify({ transactionId: tx.transactionId }, { type: "DID_FAIL_TO_RENEW" })).status).toBe(503);
    const res = await purchase(user.token, tx.transactionId);
    expect([res.status, res.body.error.code]).toEqual([503, "subscriptions_unavailable"]);
    // Nothing changed: the row still has the earlier, active transaction.
    expect(await rows(user.userId)).toMatchObject([{ status: "active", expires_at: tx.expiresDate }]);
  });
});

// MARK: Enforcement

describe("Plan enforcement", () => {
  const summary = (token: string, extra?: Partial<Env>) =>
    request("GET", "/v1/assistant/summary?date=2026-10-15", { token, env: extra });

  it("lets everyone use the assistant while enforcement is off", async () => {
    const user = await signInUser();
    expect((await summary(user.token)).status).toBe(200);
    expect((await summary(user.token, { SUBSCRIPTIONS_ENFORCED: "false" })).status).toBe(200);
  });

  it("requires pro for the assistant when enforced and free users get no requests", async () => {
    const proOnly = { ...ENFORCED, AI_MONTHLY_LIMIT_FREE: "0" };
    const free = await signInUser();
    const res = await summary(free.token, proOnly);
    expect([res.status, res.body.error.code]).toEqual([403, "pro_required"]);
    const parse = await request("POST", "/v1/assistant/parse", { token: free.token, body: { text: "مهمة" }, env: proOnly });
    expect(parse.status).toBe(403);
    expect(fakeAi.requests).toEqual([]);
    const plan = await request("GET", "/v1/subscriptions", { token: free.token, env: proOnly });
    expect(plan.body).toMatchObject({ plan: "free", enforced: true });

    const pro = await signInUser();
    await subscribe(pro);
    expect((await summary(pro.token, proOnly)).status).toBe(200);
  });

  it("lets a free user use the assistant up to AI_MONTHLY_LIMIT_FREE when enforced", async () => {
    // wrangler.jsonc gives free users 20 requests a month.
    expect(env.AI_MONTHLY_LIMIT_FREE).toBe("20");
    const free = await signInUser();
    expect((await summary(free.token, ENFORCED)).status).toBe(200);
    const vars = { ...ENFORCED, AI_MONTHLY_LIMIT_FREE: "1" };
    fakeAi.answer({ title: "مهمة", notes: null, dueDate: null, dueHijri: null, dueTime: null, duePrayer: null, duePrayerOffset: null, priority: "none", tags: [], projectId: null });
    expect((await request("POST", "/v1/assistant/parse", { token: free.token, body: { text: "مهمة" }, env: vars })).status).toBe(200);
    const over = await request("POST", "/v1/assistant/parse", { token: free.token, body: { text: "مهمة" }, env: vars });
    expect(over.status).toBe(429);
    expect(over.body.error).toMatchObject({ code: "ai_quota_exceeded", limit: 1, plan: "free" });
    expect(fakeAi.requests).toHaveLength(1);
  });

  it("treats PRO_USERS (ids or emails) as pro", async () => {
    const byId = await signInUser();
    const byEmail = await signInUser("Owner@Example.com");
    const other = await signInUser("someone@example.com");
    const overrides = { ...ENFORCED, AI_MONTHLY_LIMIT_FREE: "0", PRO_USERS: ` ${byId.userId.toUpperCase()} , owner@example.com` };
    expect((await summary(byId.token, overrides)).status).toBe(200);
    expect((await summary(byEmail.token, overrides)).status).toBe(200);
    expect((await summary(other.token, overrides)).status).toBe(403);
    const plan = await request("GET", "/v1/subscriptions", { token: byEmail.token, env: overrides });
    expect(plan.body).toMatchObject({ plan: "pro", source: "override", expiresAt: null, enforced: true });
  });

  it("requires pro for server imports when enforced, and keeps the sources list open", async () => {
    const free = await signInUser();
    const body = { source: "todoist-api", token: "0123456789abcdef" };
    const refused = await request("POST", "/v1/imports", { token: free.token, body, env: ENFORCED });
    expect([refused.status, refused.body.error.code]).toEqual([403, "pro_required"]);
    expect(enqueued).toEqual([]);
    expect((await request("GET", "/v1/imports/sources", { token: free.token, env: ENFORCED })).status).toBe(200);

    expect((await request("POST", "/v1/imports", { token: free.token, body })).status).toBe(202);
    const pro = await signInUser();
    await subscribe(pro);
    expect((await request("POST", "/v1/imports", { token: pro.token, body, env: ENFORCED })).status).toBe(202);
    expect(enqueued.length).toBe(2);
  });

  it("requires pro for MCP (ZimamService) when enforced, with an Arabic message", async () => {
    const free = await signInUser();
    const open = new ZimamService(createExecutionContext(), env);
    expect((await open.listProjects(free.userId)).ok).toBe(true);

    const enforced = new ZimamService(createExecutionContext(), { ...env, ...ENFORCED });
    for (const outcome of [
      await enforced.listTasks(free.userId, {}),
      await enforced.listProjects(free.userId),
      await enforced.getAgenda(free.userId, {}),
      await enforced.createTask(free.userId, { title: "مهمة" }),
    ]) {
      expect(outcome.ok).toBe(false);
      if (!outcome.ok) {
        expect(outcome.error.code).toBe("pro_required");
        expect(outcome.error.message).toContain("زمام الاحترافية");
      }
    }
    const tasks = await env.DB.prepare(`SELECT COUNT(*) AS n FROM tasks WHERE owner_id = ?`).bind(free.userId).first<{ n: number }>();
    expect(tasks?.n).toBe(0);

    const pro = await signInUser();
    await subscribe(pro);
    expect((await enforced.listTasks(pro.userId, {})).ok).toBe(true);
  });

  it("stops counting a subscription once the account is deleted", async () => {
    const user = await signInUser();
    await subscribe(user);
    expect((await rows(user.userId)).length).toBe(1);
    expect((await request("DELETE", "/v1/me", { token: user.token })).status).toBe(204);
    expect(await rows(user.userId)).toEqual([]);
  });
});

// MARK: The App Store client

describe("AppStoreClient", () => {
  it("signs an ES256 token for the App Store Server API and decodes the transaction", async () => {
    const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
    const pem = await exportPKCS8(privateKey);
    const tx = transaction(uuid());
    const seen: { url: string; auth: string }[] = [];
    const client = new AppStoreClient({ keyId: "KEY123", issuerId: "issuer-1", privateKeyPem: pem.replace(/\n/g, "\\n"), bundleId: "app.zimam.ios" },
      async (input, init) => {
        const url = String(input);
        seen.push({ url, auth: new Headers(init?.headers).get("Authorization") ?? "" });
        if (url.includes("storekit-sandbox")) return Response.json({ errorCode: 4040010, errorMessage: "Not found" }, { status: 404 });
        return Response.json({ signedTransactionInfo: jws(tx) });
      });

    expect(await client.getTransaction(tx.transactionId, "production")).toEqual(tx);
    expect(await client.getTransaction(tx.transactionId, "sandbox")).toBeNull();
    expect(seen.map((s) => s.url)).toEqual([
      `https://api.storekit.itunes.apple.com/inApps/v1/transactions/${tx.transactionId}`,
      `https://api.storekit-sandbox.itunes.apple.com/inApps/v1/transactions/${tx.transactionId}`,
    ]);
    const token = seen[0]!.auth.replace("Bearer ", "");
    expect(decodeProtectedHeader(token)).toEqual({ alg: "ES256", kid: "KEY123", typ: "JWT" });
    const { payload } = await jwtVerify(token, publicKey, { issuer: "issuer-1", audience: "appstoreconnect-v1" });
    expect(payload.bid).toBe("app.zimam.ios");
    expect(payload.exp! - payload.iat!).toBeLessThanOrEqual(3600);
    // The token is reused while it is fresh.
    expect(seen[1]!.auth).toBe(seen[0]!.auth);
  });

  it("reads a subscription's renewal state from Get All Subscription Statuses", async () => {
    const { privateKey } = await generateKeyPair("ES256", { extractable: true });
    const graceEnd = Date.now() + 3 * DAY;
    const seen: string[] = [];
    const client = new AppStoreClient(
      { keyId: "K", issuerId: "I", privateKeyPem: await exportPKCS8(privateKey), bundleId: "app.zimam.ios" },
      async (input) => {
        const url = String(input);
        seen.push(url);
        if (url.includes("storekit-sandbox")) return Response.json({ errorCode: 4040010 }, { status: 404 });
        return Response.json({
          environment: "Production",
          bundleId: "app.zimam.ios",
          data: [
            {
              subscriptionGroupIdentifier: "21000000",
              lastTransactions: [
                { originalTransactionId: "111", status: 1, signedTransactionInfo: jws({}), signedRenewalInfo: jws({ autoRenewStatus: 1 }) },
                {
                  originalTransactionId: "222",
                  status: 4,
                  signedTransactionInfo: jws({}),
                  signedRenewalInfo: jws({ originalTransactionId: "222", gracePeriodExpiresDate: graceEnd, isInBillingRetryPeriod: true, expirationIntent: 2, autoRenewStatus: 1 }),
                },
              ],
            },
          ],
        });
      },
    );
    expect(await client.getRenewal("222", "production")).toEqual({
      originalTransactionId: "222",
      status: 4,
      gracePeriodExpiresDate: graceEnd,
      isInBillingRetryPeriod: true,
      expirationIntent: 2,
      autoRenewStatus: 1,
    });
    expect(await client.getRenewal("111", "production")).toMatchObject({ status: 1, isInBillingRetryPeriod: false, gracePeriodExpiresDate: undefined });
    expect(await client.getRenewal("333", "production")).toBeNull();
    expect(await client.getRenewal("222", "sandbox")).toBeNull();
    expect(seen[0]).toBe("https://api.storekit.itunes.apple.com/inApps/v1/subscriptions/222");
    expect(seen.at(-1)).toBe("https://api.storekit-sandbox.itunes.apple.com/inApps/v1/subscriptions/222");
  });

  it("reports Apple's failures as AppStoreError, and needs all three secrets", async () => {
    const { privateKey } = await generateKeyPair("ES256", { extractable: true });
    const client = new AppStoreClient(
      { keyId: "K", issuerId: "I", privateKeyPem: await exportPKCS8(privateKey), bundleId: "app.zimam.ios" },
      async () => Response.json({ errorCode: 4010001 }, { status: 401 }),
    );
    await expect(client.getTransaction("1", "production")).rejects.toThrow(AppStoreError);
    await expect(client.getRenewal("1", "production")).rejects.toThrow(AppStoreError);
    expect(appStoreFromEnv(env)).toBeNull();
    expect(appStoreFromEnv({ ...env, APPSTORE_KEY_ID: "K", APPSTORE_ISSUER_ID: "I", APPSTORE_PRIVATE_KEY: "pem" })).not.toBeNull();
  });
});
