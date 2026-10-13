import { createRemoteJWKSet, type JWTVerifyGetKey, jwtVerify } from "jose";
import { sha256Hex } from "./crypto";

const APPLE_ISSUER = "https://appleid.apple.com";

/** Apple's signing keys, fetched and cached by jose. */
export const appleKeys: JWTVerifyGetKey = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

export interface AppleIdentity {
  sub: string;
  email: string | null;
}

/**
 * Verifies a Sign in with Apple identity token: Apple's signature, issuer,
 * audience (our bundle id or web Services ID), expiry, and — when the client
 * sent one — that the token carries the SHA-256 of its nonce.
 */
export async function verifyAppleToken(
  token: string,
  keys: JWTVerifyGetKey,
  audiences: string[],
  nonce?: string,
): Promise<AppleIdentity> {
  const { payload } = await jwtVerify(token, keys, {
    issuer: APPLE_ISSUER,
    audience: audiences,
    algorithms: ["RS256"],
  });
  if (typeof payload.sub !== "string" || payload.sub === "") throw new Error("Token has no subject");
  if (nonce !== undefined && payload.nonce !== (await sha256Hex(nonce))) throw new Error("Nonce mismatch");
  return { sub: payload.sub, email: typeof payload.email === "string" ? payload.email : null };
}
