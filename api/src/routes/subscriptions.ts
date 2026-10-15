import { type Context, Hono } from "hono";
import { z } from "zod";
import { fail, readJson } from "../http";
import { requireUser } from "../middleware";
import {
  type AppStore,
  AppStoreError,
  type AppStoreEnvironment,
  type AppStoreRenewal,
  type AppStoreTransaction,
  decodeAppleJws,
  findTransaction,
  needsRenewal,
} from "../subscriptions/appstore";
import { applyTransaction, checkProduct, currentPlan, ownerForApp, ownerForNotification } from "../subscriptions/entitlements";
import type { AppEnv } from "../types";

/**
 * «زمام الاحترافية» (api/DEVELOPMENT.md, «الاشتراكات»). Purchases happen in the app with
 * StoreKit; the server only believes what it fetches itself from the App Store Server API.
 */
export const subscriptions = new Hono<AppEnv>();

type Ctx = Context<AppEnv>;

const appStore = (c: Ctx): AppStore | null => c.var.deps.appStore?.(c.env) ?? null;

const unavailable = (c: Ctx) => fail(c, 503, "subscriptions_unavailable", "Subscriptions cannot be verified right now");

/**
 * The subscription's renewal state when the transaction alone cannot say whether the user is
 * still pro (`needsRenewal`): asked in the environment the transaction was found in.
 * Throws AppStoreError when Apple cannot be asked, like the transaction lookup.
 */
async function renewalFor(
  store: AppStore,
  transaction: AppStoreTransaction,
  environment: AppStoreEnvironment,
  notificationType?: string,
): Promise<AppStoreRenewal | null> {
  if (!needsRenewal(transaction, Date.now(), notificationType)) return null;
  return store.getRenewal(transaction.originalTransactionId, environment);
}

const planOut = async (c: Ctx) => {
  const { plan, expiresAt, productId, source, environment, enforced } = await currentPlan(c.env, c.var.userId);
  return { plan, expiresAt, productId, source, environment, enforced };
};

/** GET /v1/subscriptions — the user's plan now. */
subscriptions.get("/", requireUser, async (c) => c.json(await planOut(c)));

const PurchaseBody = z.object({
  /** StoreKit's Transaction.id (a decimal number, sent as text). */
  transactionId: z.string().regex(/^\d{1,32}$/),
  /** Where StoreKit says the transaction is; only decides which host is asked first. */
  environment: z.enum(["production", "sandbox"]).optional(),
});

const PROBLEMS = {
  wrong_bundle: [400, "The transaction is for another app"],
  unknown_product: [400, "The transaction is not a Zimam Pro product"],
  account_mismatch: [403, "The transaction was bought for another Zimam account"],
  already_linked: [409, "The subscription belongs to another Zimam account"],
} as const;

/**
 * POST /v1/subscriptions/apple — after a purchase or a restore, the app sends each
 * verified transaction id. The server fetches it from Apple, checks the bundle, the
 * product and the account (appAccountToken = user id), saves it, and answers the plan.
 */
subscriptions.post("/apple", requireUser, async (c) => {
  const body = PurchaseBody.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "transactionId is required");
  const store = appStore(c);
  if (!store) return unavailable(c);
  let found;
  try {
    found = await findTransaction(store, body.data.transactionId, body.data.environment ?? "production");
  } catch (error) {
    console.error(`subscriptions: lookup failed: ${error instanceof AppStoreError ? error.message : "error"}`);
    return unavailable(c);
  }
  if (!found) return fail(c, 404, "transaction_not_found", "The App Store does not know this transaction");
  const { transaction, environment } = found;
  const problem = checkProduct(c.env, transaction) ?? (await ownerForApp(c.env.DB, transaction, c.var.userId));
  if (problem) {
    const [status, message] = PROBLEMS[problem];
    return fail(c, status, problem, message);
  }
  let renewal;
  try {
    renewal = await renewalFor(store, transaction, environment);
  } catch (error) {
    console.error(`subscriptions: renewal lookup failed: ${error instanceof AppStoreError ? error.message : "error"}`);
    return unavailable(c);
  }
  await applyTransaction(c.env.DB, c.var.userId, transaction, environment, Date.now(), renewal);
  return c.json(await planOut(c));
});

/** The parts of App Store Server Notifications V2 that are read. */
interface NotificationPayload {
  notificationType?: string;
  data?: { bundleId?: string; environment?: string; signedTransactionInfo?: string };
}

/**
 * POST /v1/subscriptions/apple/notifications — App Store Server Notifications V2
 * (renewals, expiry, refunds, revocations, failed renewals and the end of the billing grace
 * period), for both environments. The payload is only a pointer: its transaction id is
 * fetched again from Apple, with the renewal state when needed, and that is what is saved.
 * 200 for anything handled or ignored; 503 when Apple could not be asked, so Apple retries.
 */
subscriptions.post("/apple/notifications", async (c) => {
  const body = (await readJson(c)) as { signedPayload?: unknown } | undefined;
  const payload = typeof body?.signedPayload === "string" ? decodeAppleJws<NotificationPayload>(body.signedPayload) : null;
  if (!payload) return fail(c, 400, "invalid", "signedPayload is required");
  const data = payload.data;
  const signed = data?.signedTransactionInfo;
  const claimed = typeof signed === "string" ? decodeAppleJws<{ transactionId?: unknown }>(signed) : null;
  const transactionId = typeof claimed?.transactionId === "string" ? claimed.transactionId : null;
  // TEST notifications and summaries carry no transaction; another app's are not ours.
  if (!transactionId || !/^\d{1,32}$/.test(transactionId) || data?.bundleId !== c.env.APPSTORE_BUNDLE_ID) {
    return c.json({ ok: true });
  }
  const store = appStore(c);
  if (!store) return unavailable(c);
  const first: AppStoreEnvironment = data?.environment === "Sandbox" ? "sandbox" : "production";
  let found;
  try {
    found = await findTransaction(store, transactionId, first);
  } catch (error) {
    console.error(`subscriptions: notification lookup failed: ${error instanceof AppStoreError ? error.message : "error"}`);
    return unavailable(c);
  }
  if (!found || checkProduct(c.env, found.transaction)) return c.json({ ok: true });
  const userId = await ownerForNotification(c.env.DB, found.transaction);
  if (!userId) {
    console.warn(`subscriptions: ${payload.notificationType ?? "notification"} for an unknown or deleted account`);
    return c.json({ ok: true });
  }
  let renewal;
  try {
    renewal = await renewalFor(store, found.transaction, found.environment, payload.notificationType);
  } catch (error) {
    console.error(`subscriptions: notification renewal lookup failed: ${error instanceof AppStoreError ? error.message : "error"}`);
    return unavailable(c);
  }
  await applyTransaction(c.env.DB, userId, found.transaction, found.environment, Date.now(), renewal);
  return c.json({ ok: true });
});
