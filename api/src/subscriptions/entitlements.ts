import { createMiddleware } from "hono/factory";
import type { Env } from "../env";
import { fail } from "../http";
import type { AppEnv } from "../types";
import type { AppStoreEnvironment, AppStoreTransaction } from "./appstore";

/**
 * «زمام الاحترافية»: who is pro, and the gate in front of pro features (the assistant,
 * MCP, server imports). See api/DEVELOPMENT.md, «الاشتراكات».
 */

/** The subscription group's products, monthly and yearly. Prices are set in App Store Connect. */
export const PRO_PRODUCTS = ["app.zimam.ios.pro.monthly", "app.zimam.ios.pro.yearly"] as const;

/** What a free user's pro request gets: the code is stable, the app shows the paywall for it. */
export const PRO_REQUIRED = {
  code: "pro_required",
  message: "This feature needs Zimam Pro",
  /** For MCP: the assistant (Claude, ChatGPT) shows the text to the user as is. */
  arabic: "هذه الميزة من مزايا «زمام الاحترافية». اشترك من تطبيق زمام على الآيفون أو الآيباد أو الماك: الإعدادات ← الاشتراك.",
} as const;

export interface Plan {
  plan: "free" | "pro";
  /** When the pro period ends (ms); null for free and for PRO_USERS. */
  expiresAt: number | null;
  productId: string | null;
  /** Where pro comes from: an App Store subscription, or the PRO_USERS override. */
  source: "apple" | "override" | null;
  environment: AppStoreEnvironment | null;
  /** False during the personal trial: nothing is blocked, whatever the plan. */
  enforced: boolean;
}

export const isEnforced = (env: Pick<Env, "SUBSCRIPTIONS_ENFORCED">) => env.SUBSCRIPTIONS_ENFORCED?.trim().toLowerCase() === "true";

/** PRO_USERS: comma-separated user ids or emails, lowercased. */
function overrides(env: Pick<Env, "PRO_USERS">): string[] {
  return (env.PRO_USERS ?? "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

async function isOverride(env: Env, userId: string): Promise<boolean> {
  const list = overrides(env);
  if (list.length === 0) return false;
  if (list.includes(userId.toLowerCase())) return true;
  const emails = list.filter((s) => s.includes("@"));
  if (emails.length === 0) return false;
  // The account's email and every linked sign-in's (Apple, Google).
  const { results } = await env.DB.prepare(
    `SELECT lower(email) AS email FROM users WHERE id = ?1 AND email IS NOT NULL AND apple_sub NOT LIKE 'deleted:%'
     UNION SELECT lower(email) FROM identities WHERE user_id = ?1 AND email IS NOT NULL`,
  )
    .bind(userId)
    .all<{ email: string }>();
  return results.some((r) => emails.includes(r.email));
}

/** The user's plan now: an unexpired, unrevoked subscription, or PRO_USERS. */
export async function currentPlan(env: Env, userId: string, now = Date.now()): Promise<Plan> {
  const enforced = isEnforced(env);
  const row = await env.DB.prepare(
    `SELECT product_id, expires_at, environment FROM entitlements
     WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY expires_at DESC LIMIT 1`,
  )
    .bind(userId, now)
    .first<{ product_id: string; expires_at: number; environment: AppStoreEnvironment }>();
  if (row) {
    return { plan: "pro", expiresAt: row.expires_at, productId: row.product_id, source: "apple", environment: row.environment, enforced };
  }
  if (await isOverride(env, userId)) {
    return { plan: "pro", expiresAt: null, productId: null, source: "override", environment: null, enforced };
  }
  return { plan: "free", expiresAt: null, productId: null, source: null, environment: null, enforced };
}

/** Whether the user may use pro features: everyone while enforcement is off. */
export async function hasProAccess(env: Env, userId: string): Promise<boolean> {
  if (!isEnforced(env)) return true;
  return (await currentPlan(env, userId)).plan === "pro";
}

/**
 * The plan whose limits apply (assistant requests, attachment storage): the user's plan when
 * enforced, and pro for everyone during the personal trial.
 */
export async function limitsPlan(env: Env, userId: string): Promise<Plan["plan"]> {
  if (!isEnforced(env)) return "pro";
  return (await currentPlan(env, userId)).plan;
}

/** Hono middleware after `requireUser`: 403 `pro_required` for a free user when enforced. */
export const requirePro = createMiddleware<AppEnv>(async (c, next) => {
  if (!(await hasProAccess(c.env, c.var.userId))) return fail(c, 403, PRO_REQUIRED.code, PRO_REQUIRED.message);
  await next();
});

// MARK: Applying a transaction

export type TransactionProblem = "wrong_bundle" | "unknown_product" | "account_mismatch" | "already_linked";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The Zimam user the app named at purchase (appAccountToken), lowercased, if it is a UUID. */
export function accountToken(transaction: AppStoreTransaction): string | null {
  const token = transaction.appAccountToken?.toLowerCase() ?? "";
  return UUID.test(token) ? token : null;
}

/** Checks the parts of a transaction that do not depend on who sends it. */
export function checkProduct(env: Env, transaction: AppStoreTransaction): TransactionProblem | null {
  if (transaction.bundleId !== env.APPSTORE_BUNDLE_ID) return "wrong_bundle";
  if (!(PRO_PRODUCTS as readonly string[]).includes(transaction.productId)) return "unknown_product";
  return null;
}

async function userState(db: D1Database, userId: string): Promise<"active" | "deleted" | "missing"> {
  const row = await db.prepare(`SELECT apple_sub FROM users WHERE id = ?`).bind(userId).first<{ apple_sub: string }>();
  if (!row) return "missing";
  return row.apple_sub.startsWith("deleted:") ? "deleted" : "active";
}

async function linkedUser(db: D1Database, originalTransactionId: string): Promise<string | null> {
  const row = await db
    .prepare(`SELECT user_id FROM entitlements WHERE original_transaction_id = ?`)
    .bind(originalTransactionId)
    .first<{ user_id: string }>();
  return row?.user_id ?? null;
}

/**
 * Who a transaction the app sent belongs to, or why it does not belong to `userId`:
 * its appAccountToken must be the user's id. One exception: a token whose Zimam account
 * was deleted, so a subscription still running with Apple can be restored into the new
 * account (the app holds the transaction, so the same Apple account is on the device).
 */
export async function ownerForApp(db: D1Database, transaction: AppStoreTransaction, userId: string): Promise<TransactionProblem | null> {
  const linked = await linkedUser(db, transaction.originalTransactionId);
  if (linked && linked !== userId) return "already_linked";
  if (linked === userId) return null;
  const token = accountToken(transaction);
  if (token === userId) return null;
  if (token && (await userState(db, token)) === "deleted") return null;
  return "account_mismatch";
}

/** Who a transaction from a notification belongs to: the linked user, else the appAccountToken's live user. */
export async function ownerForNotification(db: D1Database, transaction: AppStoreTransaction): Promise<string | null> {
  const linked = await linkedUser(db, transaction.originalTransactionId);
  if (linked) return (await userState(db, linked)) === "active" ? linked : null;
  const token = accountToken(transaction);
  return token && (await userState(db, token)) === "active" ? token : null;
}

function statusOf(transaction: AppStoreTransaction, now: number): "active" | "expired" | "revoked" {
  if (transaction.revocationDate) return "revoked";
  return transaction.expiresDate && transaction.expiresDate > now ? "active" : "expired";
}

/**
 * Saves a transaction fetched from Apple as the user's entitlement. Keeps the newest
 * transaction of the subscription: an older one (a restore sending an earlier renewal)
 * does not move the row back, but the same transaction again (a refund) updates it.
 * The old half of an upgrade within the group is skipped; its successor carries on.
 */
export async function applyTransaction(
  db: D1Database,
  userId: string,
  transaction: AppStoreTransaction,
  environment: AppStoreEnvironment,
  now = Date.now(),
): Promise<void> {
  if (transaction.isUpgraded) return;
  await db
    .prepare(
      `INSERT INTO entitlements (original_transaction_id, user_id, product_id, transaction_id, purchased_at,
         expires_at, environment, status, revoked_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
       ON CONFLICT (original_transaction_id) DO UPDATE SET
         product_id = excluded.product_id, transaction_id = excluded.transaction_id,
         purchased_at = excluded.purchased_at, expires_at = excluded.expires_at,
         environment = excluded.environment, status = excluded.status,
         revoked_at = excluded.revoked_at, updated_at = excluded.updated_at
       WHERE entitlements.user_id = excluded.user_id
         AND (excluded.purchased_at >= entitlements.purchased_at OR excluded.transaction_id = entitlements.transaction_id)`,
    )
    .bind(
      transaction.originalTransactionId,
      userId,
      transaction.productId,
      transaction.transactionId,
      transaction.purchaseDate ?? 0,
      transaction.expiresDate ?? null,
      environment,
      statusOf(transaction, now),
      transaction.revocationDate ?? null,
      now,
    )
    .run();
}
