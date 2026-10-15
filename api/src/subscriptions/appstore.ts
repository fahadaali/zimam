import { decodeJwt, importPKCS8, SignJWT } from "jose";
import type { Env } from "../env";

/**
 * The App Store Server API, as the subscriptions need it: one transaction by id.
 * Passed through `Deps.appStore` so tests use a fake.
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

export interface AppStore {
  /** The transaction as Apple has it in `environment`, or null when Apple does not know it there. */
  getTransaction(transactionId: string, environment: AppStoreEnvironment): Promise<AppStoreTransaction | null>;
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
    const url = `${HOSTS[environment]}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`;
    let response: Response;
    try {
      response = await this.fetcher(url, { headers: { Authorization: `Bearer ${await this.bearer()}`, Accept: "application/json" } });
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
    let signed: unknown;
    try {
      signed = (JSON.parse(text) as { signedTransactionInfo?: unknown }).signedTransactionInfo;
    } catch {}
    const transaction = typeof signed === "string" ? decodeAppleJws<AppStoreTransaction>(signed) : null;
    if (!transaction || typeof transaction.transactionId !== "string") {
      throw new AppStoreError(`App Store ${environment} returned no transaction`);
    }
    return transaction;
  }
}
