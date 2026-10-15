import type { AppleIdentity } from "./apple";
import type { AppleTokens } from "./apple-tokens";
import type { Row } from "../data/rows";

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** An authorization code from Sign in with Apple, and the redirect URI a web page requested it with. */
export interface AppleCode {
  authorizationCode: string;
  /** Only for Sign in with Apple JS (the web, the MCP consent page); checked against `appleRedirectUris`. */
  redirectUri?: string;
}

/**
 * Exchanges the client's authorization code for Apple's refresh token and keeps it
 * on the user, so deleting the account can revoke it. Failures are logged and
 * never block sign-in; the token from the latest sign-in replaces the last one.
 * A redirect URI outside `allowedRedirects` is not sent to Apple: the code is dropped.
 */
export async function storeAppleRefreshToken(
  db: D1Database,
  apple: AppleTokens | null,
  userId: string,
  identity: AppleIdentity,
  code: AppleCode,
  allowedRedirects: string[],
) {
  if (code.redirectUri !== undefined && !allowedRedirects.includes(code.redirectUri)) {
    console.warn("Apple authorization code came with a redirect URI outside APPLE_WEB_REDIRECT_URI and APPLE_REDIRECT_URIS; ignored");
    return;
  }
  if (!apple) {
    console.warn("Sign in with Apple key is not configured (APPLE_KEY_ID, APPLE_PRIVATE_KEY); not keeping a refresh token");
    return;
  }
  try {
    const { refreshToken, sub } = await apple.exchangeCode(code.authorizationCode, identity.audience, code.redirectUri);
    if (sub !== null && sub !== identity.sub) {
      console.warn("Apple authorization code belongs to another user; ignored");
      return;
    }
    await db
      .prepare(`UPDATE users SET apple_refresh_token = ?2, apple_client_id = ?3 WHERE id = ?1`)
      .bind(userId, refreshToken, identity.audience)
      .run();
  } catch (e) {
    console.warn(`Apple authorization code exchange failed: ${message(e)}`);
  }
}

/**
 * Revokes the user's Sign in with Apple authorization, as App Store guideline
 * 5.1.1(v) asks when an account is deleted. Without a stored token or the key,
 * or when Apple fails, it logs and returns, so deletion still completes.
 */
export async function revokeAppleAuthorization(apple: () => AppleTokens | null, user: Row) {
  const refreshToken = user.apple_refresh_token as string | null;
  const clientId = user.apple_client_id as string | null;
  if (!refreshToken || !clientId) return;
  const client = apple();
  if (!client) {
    console.warn("Sign in with Apple key is not configured; skipped revoking the deleted account's Apple token");
    return;
  }
  try {
    await client.revoke(refreshToken, clientId);
  } catch (e) {
    console.warn(`Revoking the deleted account's Apple token failed: ${message(e)}`);
  }
}
