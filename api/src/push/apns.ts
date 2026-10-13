import { importPKCS8, SignJWT } from "jose";
import type { Env } from "../env";

/**
 * Sends notifications through Apple Push Notification service with token-based auth:
 * a provider JWT (ES256) signed with the APNs key from the Worker's secrets
 * (APNS_KEY_ID, APNS_PRIVATE_KEY) and the team id (APNS_TEAM_ID). The key never
 * enters the repository or the app.
 */

export type PushEnvironment = "sandbox" | "production";

export interface PushMessage {
  /** APNs device token, hex. */
  token: string;
  environment: PushEnvironment;
  /** The app's bundle id (`apns-topic`). */
  topic: string;
  /** The JSON body: `{ aps: {...}, ...custom keys }`. */
  payload: Record<string, unknown>;
  /** Unix seconds after which APNs stops trying to deliver; 0 = try once. */
  expiration?: number;
  /** `apns-collapse-id`: a newer notification with the same id replaces the older one. */
  collapseId?: string;
}

export interface PushResult {
  /** HTTP status from APNs; 0 when it could not be reached. */
  status: number;
  /** APNs `reason` on failure, e.g. "BadDeviceToken", "Unregistered". */
  reason?: string;
}

export interface PushSender {
  send(message: PushMessage): Promise<PushResult>;
}

/** The token will never work again: the app was removed, or it belongs to another app or environment. */
export function isDeadToken(result: PushResult): boolean {
  return (
    result.status === 410 ||
    (result.status === 400 && (result.reason === "BadDeviceToken" || result.reason === "DeviceTokenNotForTopic"))
  );
}

const HOSTS: Record<PushEnvironment, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

/** Apple accepts a provider token for 60 minutes and rejects refreshing it more than once per 20. */
export const PROVIDER_TOKEN_REFRESH_MS = 50 * 60 * 1000;

export interface CachedToken {
  token: string;
  issuedAt: number;
}

/** Where the provider token is kept between requests and isolates. */
export interface TokenStore {
  get(keyId: string): Promise<CachedToken | null>;
  put(keyId: string, value: CachedToken): Promise<void>;
}

/** Per-isolate memory in front of D1, so every isolate and cron run shares one token. */
export class D1TokenStore implements TokenStore {
  private static memory = new Map<string, CachedToken>();

  constructor(private readonly db: D1Database) {}

  async get(keyId: string): Promise<CachedToken | null> {
    const cached = D1TokenStore.memory.get(keyId);
    if (cached) return cached;
    const row = await this.db
      .prepare(`SELECT token, issued_at FROM apns_tokens WHERE key_id = ?`)
      .bind(keyId)
      .first<{ token: string; issued_at: number }>();
    if (!row) return null;
    const value = { token: row.token, issuedAt: row.issued_at };
    D1TokenStore.memory.set(keyId, value);
    return value;
  }

  async put(keyId: string, value: CachedToken): Promise<void> {
    D1TokenStore.memory.set(keyId, value);
    await this.db
      .prepare(
        `INSERT INTO apns_tokens (key_id, token, issued_at) VALUES (?1, ?2, ?3)
         ON CONFLICT (key_id) DO UPDATE SET token = excluded.token, issued_at = excluded.issued_at`,
      )
      .bind(keyId, value.token, value.issuedAt)
      .run();
  }

  /** Tests start from an empty memory. */
  static clearMemory() {
    D1TokenStore.memory.clear();
  }
}

export class MemoryTokenStore implements TokenStore {
  private readonly map = new Map<string, CachedToken>();
  async get(keyId: string) {
    return this.map.get(keyId) ?? null;
  }
  async put(keyId: string, value: CachedToken) {
    this.map.set(keyId, value);
  }
}

export interface ApnsOptions {
  teamId: string;
  keyId: string;
  /** The .p8 file's contents (PKCS #8 PEM). Escaped "\n" and a bare base64 body are accepted. */
  privateKey: string;
  store: TokenStore;
  fetch?: typeof fetch;
  now?: () => number;
}

/** Accepts the key as pasted into `wrangler secret put`: full PEM, PEM with literal "\n", or the base64 body alone. */
export function normalizePem(key: string): string {
  const text = key.replace(/\\n/g, "\n").trim();
  if (text.includes("-----BEGIN")) return text;
  const body = text.replace(/\s+/g, "");
  const lines = body.match(/.{1,64}/g) ?? [];
  return `-----BEGIN PRIVATE KEY-----\n${lines.join("\n")}\n-----END PRIVATE KEY-----`;
}

export class ApnsSender implements PushSender {
  private signingKey: CryptoKey | null = null;

  constructor(private readonly o: ApnsOptions) {}

  private now() {
    return this.o.now ? this.o.now() : Date.now();
  }

  /** The cached provider token, or a new one when it is 50 minutes old (or `force`). */
  async providerToken(force = false): Promise<string> {
    const now = this.now();
    if (!force) {
      const cached = await this.o.store.get(this.o.keyId);
      if (cached && now - cached.issuedAt < PROVIDER_TOKEN_REFRESH_MS && cached.issuedAt <= now) return cached.token;
    }
    this.signingKey ??= await importPKCS8(normalizePem(this.o.privateKey), "ES256");
    const token = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: this.o.keyId })
      .setIssuer(this.o.teamId)
      .setIssuedAt(Math.floor(now / 1000))
      .sign(this.signingKey);
    await this.o.store.put(this.o.keyId, { token, issuedAt: now });
    return token;
  }

  async send(message: PushMessage): Promise<PushResult> {
    let result = await this.post(message, await this.providerToken());
    // Another isolate may hold a newer token, or Apple expired ours early: sign a new one once.
    if (result.status === 403 && (result.reason === "ExpiredProviderToken" || result.reason === "InvalidProviderToken")) {
      result = await this.post(message, await this.providerToken(true));
    }
    return result;
  }

  private async post(message: PushMessage, providerToken: string): Promise<PushResult> {
    const headers: Record<string, string> = {
      authorization: `bearer ${providerToken}`,
      "apns-push-type": "alert",
      "apns-topic": message.topic,
      "apns-priority": "10",
      "apns-expiration": String(message.expiration ?? 0),
      "content-type": "application/json",
    };
    if (message.collapseId) headers["apns-collapse-id"] = message.collapseId;
    const url = `${HOSTS[message.environment]}/3/device/${message.token}`;
    let response: Response;
    try {
      // APNs speaks HTTP/2 only; the Workers runtime negotiates it over TLS (ALPN).
      response = await (this.o.fetch ?? fetch)(url, { method: "POST", headers, body: JSON.stringify(message.payload) });
    } catch (err) {
      return { status: 0, reason: (err as Error).message };
    }
    if (response.ok) {
      await response.body?.cancel();
      return { status: response.status };
    }
    let reason: string | undefined;
    try {
      reason = ((await response.json()) as { reason?: string }).reason;
    } catch {
      reason = undefined;
    }
    return { status: response.status, reason };
  }
}

/** The sender for the Worker's secrets, or null (and pushes are skipped) when they are not set. */
export function apnsFromEnv(env: Env): PushSender | null {
  if (!env.APNS_KEY_ID || !env.APNS_PRIVATE_KEY || !env.APNS_TEAM_ID) return null;
  return new ApnsSender({
    teamId: env.APNS_TEAM_ID,
    keyId: env.APNS_KEY_ID,
    privateKey: env.APNS_PRIVATE_KEY,
    store: new D1TokenStore(env.DB),
  });
}
