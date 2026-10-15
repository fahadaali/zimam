import { decodeJwt, importPKCS8, SignJWT } from "jose";
import type { Env } from "../env";

/**
 * The App Store Server API, as the subscriptions need it: one transaction by id, and a
 * subscription's renewal state (for the billing grace period). Passed through
 * `Deps.appStore` so tests use a fake.
 *
 * Why decoding is enough: the transaction is fetched by the server from Apple, over TLS,
 * with a token signed by our In-App Purchase key. Nothing in it came from a client. So
 * the JWS `signedTransactionInfo` is decoded, not verified against Apple's x5c chain.
 * A notification's own payload is never trusted: only its transaction id is used, to
 * fetch the transaction again here (src/routes/subscriptions.ts).
 */

export type AppStoreEnvironment = "production" | "sandbox";

const HOSTS: Record<AppStoreEnvironment, string> = {
  production: "https://api.storekit.itunes.apple.com",
  sandbox: "https://api.storekit-sandbox.itunes.apple.com",
};

/** The fields of Apple's JWSTransactionDecodedPayload that Zimam reads. Dates are ms since 1970. */
export interface AppStoreTransaction {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  purchaseDate?: number;
  expiresDate?: number;
  /** The UUID the app set at purchase: the Zimam user id. */
  appAccountToken?: string;
  /** "Production", "Sandbox" (TestFlight, App Review, sandbox accounts). */
  environment?: string;
  revocationDate?: number;
  revocationReason?: number;
  /** True for the old transaction of a subscription upgraded within the group. */
  isUpgraded?: boolean;
  type?: string;
}

/**
 * A subscription's state from Get All Subscription Statuses, with the fields of its
 * JWSRenewalInfoDecodedPayload that Zimam reads. Dates are ms since 1970.
 */
export interface AppStoreRenewal {
  originalTransactionId: string;
  /** 1 active, 2 expired, 3 in billing retry, 4 in the billing grace period, 5 revoked. */
  status: number;
  /** While in the billing grace period: when it ends. Pro lasts until then. */
  gracePeriodExpiresDate?: number;
  /** Apple is still trying to charge for the renewal (the grace period is the start of this). */
  isInBillingRetryPeriod?: boolean;
  /** Why it expired: 1 cancelled, 2 billing error, 3 price increase refused, 4 product unavailable, 5 other. */
  expirationIntent?: number;
  autoRenewStatus?: number;
}

export interface AppStore {
  /** The transaction as Apple has it in `environment`, or null when Apple does not know it there. */
  getTransaction(transactionId: string, environment: AppStoreEnvironment): Promise<AppStoreTransaction | null>;
  /**
   * The renewal state of the subscription `originalTransactionId` started (GET
   * /inApps/v1/subscriptions/{id}), or null when Apple does not know it in `environment`.
   */
  getRenewal(originalTransactionId: string, environment: AppStoreEnvironment): Promise<AppStoreRenewal | null>;
}

/** Apple could not be reached or refused our key: the caller answers 503 and Apple's retries (or the app's) try again. */
export class AppStoreError extends Error {}

/**
 * Looks a transaction up where it most likely is, then in the other environment, as Apple
 * recommends (production first). Returns the transaction and where it was found.
 */
export async function findTransaction(
  store: AppStore,
  transactionId: string,
  first: AppStoreEnvironment = "production",
): Promise<{ transaction: AppStoreTransaction; environment: AppStoreEnvironment } | null> {
  const order: AppStoreEnvironment[] = first === "production" ? ["production", "sandbox"] : ["sandbox", "production"];
  for (const environment of order) {
    const transaction = await store.getTransaction(transactionId, environment);
    if (transaction) return { transaction, environment };
  }
  return null;
}

/** Notifications after which the renewal state is read again, whatever the transaction says. */
const RENEWAL_NOTIFICATIONS = new Set(["DID_FAIL_TO_RENEW", "GRACE_PERIOD_EXPIRED"]);

/**
 * Whether the renewal state is needed to know if the user is still pro: an expired (not
 * revoked) subscription may be in the billing grace period, and a failed renewal or the end
 * of the grace period changes it. An active or refunded one is answered by its transaction.
 */
export function needsRenewal(transaction: AppStoreTransaction, now: number, notificationType?: string): boolean {
  if (transaction.revocationDate || transaction.isUpgraded) return false;
  if (notificationType && RENEWAL_NOTIFICATIONS.has(notificationType)) return true;
  return !transaction.expiresDate || transaction.expiresDate <= now;
}

/** Reads the payload of a JWS from Apple (signedTransactionInfo, signedPayload) without verifying it. */
export function decodeAppleJws<T>(jws: string): T | null {
  try {
    return decodeJwt(jws) as T;
  } catch {
    return null;
  }
}

/** Builds the App Store client from the Worker's secrets, or null when any is missing. */
export function appStoreFromEnv(env: Env, fetcher: typeof fetch = fetch): AppStore | null {
  const { APPSTORE_KEY_ID: keyId, APPSTORE_ISSUER_ID: issuerId, APPSTORE_PRIVATE_KEY: privateKey } = env;
  const bundleId = env.APPSTORE_BUNDLE_ID;
  if (!keyId || !issuerId || !privateKey || !bundleId) return null;
  return new AppStoreClient({ keyId, issuerId, privateKeyPem: privateKey, bundleId }, fetcher);
}

/** Apple accepts tokens up to an hour; ours live five minutes and are reused within that. */
const TOKEN_TTL_SECONDS = 5 * 60;

export class AppStoreClient implements AppStore {
  private key?: Promise<CryptoKey>;
  private token?: { value: string; expires: number };

  constructor(
    private readonly config: { keyId: string; issuerId: string; privateKeyPem: string; bundleId: string },
    private readonly fetcher: typeof fetch = fetch,
  ) {}

  /** The ES256 bearer token of the App Store Server API, signed with the In-App Purchase key. */
  async bearer(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (this.token && this.token.expires - 30 > now) return this.token.value;
    // `wrangler secret put` may keep the .p8 newlines as literal "\n".
    this.key ??= importPKCS8(this.config.privateKeyPem.replace(/\\n/g, "\n").trim(), "ES256");
    const value = await new SignJWT({ bid: this.config.bundleId })
      .setProtectedHeader({ alg: "ES256", kid: this.config.keyId, typ: "JWT" })
      .setIssuer(this.config.issuerId)
      .setIssuedAt(now)
      .setExpirationTime(now + TOKEN_TTL_SECONDS)
      .setAudience("appstoreconnect-v1")
      .sign(await this.key);
    this.token = { value, expires: now + TOKEN_TTL_SECONDS };
    return value;
  }

  async getTransaction(transactionId: string, environment: AppStoreEnvironment): Promise<AppStoreTransaction | null> {
    const body = await this.get(environment, `/inApps/v1/transactions/${encodeURIComponent(transactionId)}`);
    if (body === null) return null;
    const signed = (body as { signedTransactionInfo?: unknown }).signedTransactionInfo;
    const transaction = typeof signed === "string" ? decodeAppleJws<AppStoreTransaction>(signed) : null;
    if (!transaction || typeof transaction.transactionId !== "string") {
      throw new AppStoreError(`App Store ${environment} returned no transaction`);
    }
    return transaction;
  }

  async getRenewal(originalTransactionId: string, environment: AppStoreEnvironment): Promise<AppStoreRenewal | null> {
    const body = await this.get(environment, `/inApps/v1/subscriptions/${encodeURIComponent(originalTransactionId)}`);
    if (body === null) return null;
    // StatusResponse: data[] by subscription group, each with lastTransactions[] by subscription.
    type Item = { originalTransactionId?: unknown; status?: unknown; signedRenewalInfo?: unknown };
    const groups = (body as { data?: { lastTransactions?: Item[] }[] }).data;
    const items = Array.isArray(groups) ? groups.flatMap((g) => (Array.isArray(g?.lastTransactions) ? g.lastTransactions : [])) : [];
    const item = items.find((i) => i?.originalTransactionId === originalTransactionId);
    if (!item) return null;
    const info = typeof item.signedRenewalInfo === "string" ? decodeAppleJws<Partial<AppStoreRenewal>>(item.signedRenewalInfo) : null;
    return {
      originalTransactionId,
      status: typeof item.status === "number" ? item.status : 0,
      gracePeriodExpiresDate: typeof info?.gracePeriodExpiresDate === "number" ? info.gracePeriodExpiresDate : undefined,
      isInBillingRetryPeriod: info?.isInBillingRetryPeriod === true,
      expirationIntent: typeof info?.expirationIntent === "number" ? info.expirationIntent : undefined,
      autoRenewStatus: typeof info?.autoRenewStatus === "number" ? info.autoRenewStatus : undefined,
    };
  }

  /** A GET with our token: the JSON body, or null for 404 (not found) and 400 (not a valid id). */
  private async get(environment: AppStoreEnvironment, path: string): Promise<unknown> {
    let response: Response;
    try {
      response = await this.fetcher(`${HOSTS[environment]}${path}`, {
        headers: { Authorization: `Bearer ${await this.bearer()}`, Accept: "application/json" },
      });
    } catch (error) {
      throw new AppStoreError(`App Store ${environment}: ${error instanceof Error ? error.name : "network error"}`);
    }
    const text = await response.text();
    // 404 TransactionIdNotFoundError (4040010); 400 InvalidTransactionIdError (4000006).
    if (response.status === 404 || response.status === 400) return null;
    if (!response.ok) {
      let reason = `HTTP ${response.status}`;
      try {
        const body = JSON.parse(text) as { errorCode?: unknown };
        if (body.errorCode !== undefined) reason += ` ${String(body.errorCode)}`;
      } catch {}
      throw new AppStoreError(`App Store ${environment} failed: ${reason}`);
    }
    try {
      return JSON.parse(text) as unknown;
    } catch {
      throw new AppStoreError(`App Store ${environment} returned an unreadable answer`);
    }
  }
}
