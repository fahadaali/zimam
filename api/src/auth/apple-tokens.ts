import { decodeJwt, importPKCS8, SignJWT } from "jose";
import type { Env } from "../env";

const APPLE = "https://appleid.apple.com";

/**
 * Sign in with Apple's token endpoints, used to keep a refresh token at
 * sign-in and revoke it when the account is deleted (App Store guideline
 * 5.1.1(v)). Passed through `Deps` so tests use a fake.
 */
export interface AppleTokens {
  /**
   * Exchanges an authorization code for a refresh token and the Apple user it belongs to.
   * A code from Sign in with Apple JS (the web, the MCP consent page) needs the same
   * `redirectUri` it was requested with; the app's codes have none.
   */
  exchangeCode(code: string, clientId: string, redirectUri?: string): Promise<{ refreshToken: string; sub: string | null }>;
  /** Revokes a refresh token, ending the user's Sign in with Apple authorization for that client. */
  revoke(refreshToken: string, clientId: string): Promise<void>;
}

export class AppleTokenError extends Error {}

/**
 * The redirect URIs a Sign in with Apple JS page may say it used: the web app's
 * (APPLE_WEB_REDIRECT_URI) and the others in APPLE_REDIRECT_URIS (the MCP consent page).
 * Each must also be a Return URL of the web Services ID in the Apple developer account.
 */
export function appleRedirectUris(env: Pick<Env, "APPLE_WEB_REDIRECT_URI" | "APPLE_REDIRECT_URIS">): string[] {
  return [env.APPLE_WEB_REDIRECT_URI ?? "", ...(env.APPLE_REDIRECT_URIS ?? "").split(",")].map((u) => u.trim()).filter(Boolean);
}

/** The client secret lives up to 6 months; ours is short-lived and made per call. */
const SECRET_TTL_SECONDS = 5 * 60;

/**
 * Builds the Apple client from the Worker's config, or null when the Sign in
 * with Apple key is not configured (sign-in and deletion then skip Apple).
 */
export function appleTokensFromEnv(env: Env, fetcher: typeof fetch = fetch): AppleTokens | null {
  const { APPLE_TEAM_ID: teamId, APPLE_KEY_ID: keyId, APPLE_PRIVATE_KEY: privateKey } = env;
  if (!teamId || !keyId || !privateKey) return null;
  return new AppleTokenClient(teamId, keyId, privateKey, fetcher);
}

export class AppleTokenClient implements AppleTokens {
  private key?: Promise<CryptoKey>;

  constructor(
    private readonly teamId: string,
    private readonly keyId: string,
    private readonly privateKeyPem: string,
    private readonly fetcher: typeof fetch = fetch,
  ) {}

  /** The ES256 JWT Apple accepts as `client_secret`, signed with the Sign in with Apple key. */
  async clientSecret(clientId: string): Promise<string> {
    // `wrangler secret put` may keep the .p8 newlines as literal "\n".
    this.key ??= importPKCS8(this.privateKeyPem.replace(/\\n/g, "\n").trim(), "ES256");
    const now = Math.floor(Date.now() / 1000);
    return new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: this.keyId })
      .setIssuer(this.teamId)
      .setIssuedAt(now)
      .setExpirationTime(now + SECRET_TTL_SECONDS)
      .setAudience(APPLE)
      .setSubject(clientId)
      .sign(await this.key);
  }

  async exchangeCode(code: string, clientId: string, redirectUri?: string) {
    const fields: Record<string, string> = { code, grant_type: "authorization_code" };
    if (redirectUri) fields.redirect_uri = redirectUri;
    const body = await this.post("/auth/token", clientId, fields);
    const { refresh_token: refreshToken, id_token: idToken } = (body ?? {}) as { refresh_token?: unknown; id_token?: unknown };
    if (typeof refreshToken !== "string" || refreshToken === "") throw new AppleTokenError("Apple returned no refresh token");
    let sub: string | null = null;
    if (typeof idToken === "string") {
      // Straight from Apple over TLS with our client secret, so decoding is enough.
      const claims = decodeJwt(idToken);
      sub = typeof claims.sub === "string" ? claims.sub : null;
    }
    return { refreshToken, sub };
  }

  async revoke(refreshToken: string, clientId: string) {
    await this.post("/auth/revoke", clientId, { token: refreshToken, token_type_hint: "refresh_token" });
  }

  private async post(path: string, clientId: string, fields: Record<string, string>): Promise<unknown> {
    const form = new URLSearchParams({ client_id: clientId, client_secret: await this.clientSecret(clientId), ...fields });
    const response = await this.fetcher(`${APPLE}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
      body: form.toString(),
    });
    const text = await response.text();
    if (!response.ok) {
      // Apple answers `{ error: "invalid_grant" }` and the like; never log the token or code.
      let reason = `HTTP ${response.status}`;
      try {
        reason = String((JSON.parse(text) as { error?: unknown }).error ?? reason);
      } catch {}
      throw new AppleTokenError(`Apple ${path} failed: ${reason}`);
    }
    return text ? JSON.parse(text) : null;
  }
}
