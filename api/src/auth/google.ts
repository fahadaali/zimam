import { createRemoteJWKSet, type JWTVerifyGetKey, jwtVerify } from "jose";
import { sha256Hex } from "./crypto";

/** Google signs ID tokens with either form of its issuer. */
const GOOGLE_ISSUERS = ["accounts.google.com", "https://accounts.google.com"];

/** Google's signing keys, fetched and cached by jose. */
export const googleKeys: JWTVerifyGetKey = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));

export interface GoogleIdentity {
  sub: string;
  email: string | null;
  /**
   * Whether Google is authoritative for the address, so it may merge accounts: verified,
   * and either a Gmail address or a Google Workspace account (the `hd` claim). Google
   * verifies other addresses only once, when they are added, and ownership can change.
   */
  emailVerified: boolean;
  name: string | null;
}

/**
 * Verifies a Google ID token: Google's signature, issuer, audience (one of our
 * OAuth client IDs), expiry, and — when the client sent one — that the token
 * carries the SHA-256 (hex) of its nonce, as with Sign in with Apple.
 */
export async function verifyGoogleToken(
  token: string,
  keys: JWTVerifyGetKey,
  audiences: string[],
  nonce?: string,
): Promise<GoogleIdentity> {
  if (audiences.length === 0) throw new Error("No Google client IDs configured");
  const { payload } = await jwtVerify(token, keys, {
    issuer: GOOGLE_ISSUERS,
    audience: audiences,
    algorithms: ["RS256"],
  });
  if (typeof payload.sub !== "string" || payload.sub === "") throw new Error("Token has no subject");
  if (nonce !== undefined && payload.nonce !== (await sha256Hex(nonce))) throw new Error("Nonce mismatch");
  const email = typeof payload.email === "string" && payload.email !== "" ? payload.email : null;
  const verified = payload.email_verified === true || payload.email_verified === "true";
  const authoritative = typeof payload.hd === "string" && payload.hd !== "" || /@(gmail|googlemail)\.com$/i.test(email ?? "");
  const emailVerified = email !== null && verified && authoritative;
  const name = typeof payload.name === "string" && payload.name.trim() !== "" ? payload.name.trim().slice(0, 200) : null;
  return { sub: payload.sub, email, emailVerified, name };
}

/** Google OAuth client IDs configured for this deployment (GOOGLE_CLIENT_IDS). */
export function googleAudiences(value: string | undefined): string[] {
  return (value ?? "").split(",").map((a) => a.trim()).filter(Boolean);
}
