import type { Row } from "../data/rows";

export type Provider = "apple" | "google";

/** A Sign in with Apple or Google account whose token the server verified. */
export interface SignInIdentity {
  provider: Provider;
  sub: string;
  email: string | null;
  /** The provider confirmed the address belongs to this account. */
  emailVerified: boolean;
}

/** Apple's Hide My Email addresses: one per app, so they never identify the same person elsewhere. */
const PRIVATE_RELAY = "@privaterelay.appleid.com";

/**
 * The address an identity may be matched on, lowercased: only one its provider
 * verified, and never an Apple private relay address. Null when it may not match.
 */
export function matchableEmail(identity: Pick<SignInIdentity, "email" | "emailVerified">): string | null {
  if (!identity.emailVerified || !identity.email) return null;
  const email = identity.email.toLowerCase();
  return email.endsWith(PRIVATE_RELAY) ? null : email;
}

/**
 * Finds or creates the user for a verified Apple or Google identity, and returns it.
 *
 * - An identity seen before signs in to its user.
 * - A new Apple identity whose subject is already a user's `apple_sub` (created before
 *   identities existed) is attached to that user.
 * - A new identity whose verified email matches exactly one user's verified identity
 *   (any provider; private relay addresses never match) is attached to that user, so
 *   Sign in with Apple and Google reach the same account.
 * - Anything else starts a new user.
 *
 * The name is kept from the first sign-in that gave one (Apple sends it only once).
 * The account's email follows the identity it came from, and is filled from a newly
 * attached identity only when the account has none.
 */
export async function signInUser(db: D1Database, identity: SignInIdentity, name: string | null): Promise<Row> {
  const now = Date.now();
  let userId: string;
  let previousEmail: string | null = null;

  const found = await findIdentity(db, identity);
  if (found) {
    userId = found.userId;
    previousEmail = found.email;
    if (identity.email !== null) {
      await db
        .prepare(`UPDATE identities SET email = ?3, email_verified = ?4 WHERE provider = ?1 AND subject = ?2`)
        .bind(identity.provider, identity.sub, identity.email, identity.emailVerified ? 1 : 0)
        .run();
    }
  } else {
    const email = matchableEmail(identity);
    const existing = (await legacyAppleUser(db, identity)) ?? (email ? await onlyUserWithEmail(db, email) : null);
    if (existing) {
      await attachIdentity(db, identity, existing, now);
    } else {
      try {
        await createUser(db, identity, name, now);
      } catch (e) {
        // A concurrent first sign-in with the same identity won the race; use its user.
        if (!(await findIdentity(db, identity))) throw e;
      }
    }
    const linked = await findIdentity(db, identity);
    if (!linked) throw new Error("Identity link failed");
    userId = linked.userId;
  }

  await db
    .prepare(
      `UPDATE users SET name = COALESCE(name, ?2),
         email = CASE WHEN ?3 IS NOT NULL AND (email IS NULL OR email = ?4) THEN ?3 ELSE email END,
         updated_at = ?5
       WHERE id = ?1`,
    )
    .bind(userId, name, identity.email, previousEmail, now)
    .run();
  const user = await db.prepare(`SELECT * FROM users WHERE id = ?`).bind(userId).first<Row>();
  if (!user) throw new Error("User sign-in failed");
  return user;
}

async function findIdentity(db: D1Database, identity: SignInIdentity) {
  const row = await db
    .prepare(`SELECT user_id, email FROM identities WHERE provider = ? AND subject = ?`)
    .bind(identity.provider, identity.sub)
    .first<{ user_id: string; email: string | null }>();
  return row ? { userId: row.user_id, email: row.email } : null;
}

/** A user the code before identities created for this Apple subject, e.g. between the migration and the deploy. */
async function legacyAppleUser(db: D1Database, identity: SignInIdentity): Promise<string | null> {
  if (identity.provider !== "apple") return null;
  const row = await db.prepare(`SELECT id FROM users WHERE apple_sub = ?`).bind(identity.sub).first<{ id: string }>();
  return row?.id ?? null;
}

/** The single user with a verified identity at this (lowercased) address, or null for none or several. */
async function onlyUserWithEmail(db: D1Database, email: string): Promise<string | null> {
  const { results } = await db
    .prepare(`SELECT DISTINCT user_id FROM identities WHERE lower(email) = ? AND email_verified = 1 LIMIT 2`)
    .bind(email)
    .all<{ user_id: string }>();
  return results.length === 1 ? results[0]!.user_id : null;
}

function insertIdentity(db: D1Database, identity: SignInIdentity, userId: string, now: number) {
  return db
    .prepare(
      `INSERT INTO identities (provider, subject, user_id, email, email_verified, created_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (provider, subject) DO NOTHING`,
    )
    .bind(identity.provider, identity.sub, userId, identity.email, identity.emailVerified ? 1 : 0, now);
}

async function attachIdentity(db: D1Database, identity: SignInIdentity, userId: string, now: number) {
  await insertIdentity(db, identity, userId, now).run();
}

/**
 * A new user and its first identity, in one transaction. `apple_sub` keeps the Apple
 * subject, or a placeholder for a Google account. If a concurrent sign-in linked the
 * identity first, the new user is removed again.
 */
async function createUser(db: D1Database, identity: SignInIdentity, name: string | null, now: number) {
  const id = crypto.randomUUID();
  const appleSub = identity.provider === "apple" ? identity.sub : `none:${id}`;
  await db.batch([
    db
      .prepare(`INSERT INTO users (id, apple_sub, email, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`)
      .bind(id, appleSub, identity.email, name, now, now),
    insertIdentity(db, identity, id, now),
    db.prepare(`DELETE FROM users WHERE id = ?1 AND NOT EXISTS (SELECT 1 FROM identities WHERE user_id = ?1)`).bind(id),
  ]);
}

/** Sign in with Apple audiences configured for this deployment. */
export function appleAudiences(value: string): string[] {
  return value.split(",").map((a) => a.trim()).filter(Boolean);
}
