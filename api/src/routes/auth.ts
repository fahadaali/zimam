import { Hono } from "hono";
import { z } from "zod";
import { storeAppleRefreshToken } from "../auth/account";
import { verifyAppleToken } from "../auth/apple";
import { appleRedirectUris } from "../auth/apple-tokens";
import { sha256Hex } from "../auth/crypto";
import { googleAudiences, verifyGoogleToken } from "../auth/google";
import { createSession, deleteSession } from "../auth/sessions";
import { appleAudiences, signInUser } from "../auth/users";
import { userOut } from "../data/rows";
import { fail, readJson } from "../http";
import { requireUser } from "../middleware";
import { closeSockets } from "../realtime/notify";
import type { AppEnv } from "../types";

const AppleSignIn = z.object({
  identityToken: z.string().min(1),
  /** The raw nonce the client hashed into the Apple request. Every client sends one. */
  nonce: z.string().min(1).max(200),
  /** Apple sends the name only on the first sign-in, to the client. */
  name: z.string().trim().max(200).optional(),
  device: z.string().trim().max(100).optional(),
  /** Apple's one-time authorization code, exchanged for a refresh token that account deletion revokes. */
  authorizationCode: z.string().min(1).max(1000).optional(),
  /** The redirect URI a web page gave Sign in with Apple JS; the code is exchanged with it. */
  redirectUri: z.string().url().max(500).optional(),
});

const GoogleSignIn = z.object({
  idToken: z.string().min(1),
  /** The raw nonce whose SHA-256 (hex) the client gave Google. Every client sends one. */
  nonce: z.string().min(1).max(200),
  /** A name from the client; the token's own name is the fallback. */
  name: z.string().trim().max(200).optional(),
  device: z.string().trim().max(100).optional(),
});

export const auth = new Hono<AppEnv>();

auth.post("/apple", async (c) => {
  const body = AppleSignIn.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "identityToken and nonce are required");
  const audiences = appleAudiences(c.env.APPLE_AUDIENCES);

  let identity;
  try {
    identity = await verifyAppleToken(body.data.identityToken, c.var.deps.appleKeys, audiences, body.data.nonce);
  } catch {
    return fail(c, 401, "invalid_token", "Apple identity token was rejected");
  }

  const db = c.env.DB;
  const user = await signInUser(db, { provider: "apple", ...identity }, body.data.name || null);
  if (body.data.authorizationCode) {
    // Never blocks sign-in: without the Apple key, or with a bad code, the user still gets in.
    const code = { authorizationCode: body.data.authorizationCode, redirectUri: body.data.redirectUri };
    await storeAppleRefreshToken(db, c.var.deps.appleTokens(c.env), user.id as string, identity, code, appleRedirectUris(c.env));
  }

  const token = await createSession(db, user.id as string, body.data.device ?? null);
  return c.json({ token, user: userOut(user) });
});

/**
 * Sign in with Google, answered like `/apple`. A first Google sign-in whose verified
 * email matches one existing account joins it (see `signInUser`).
 */
auth.post("/google", async (c) => {
  const audiences = googleAudiences(c.env.GOOGLE_CLIENT_IDS);
  if (audiences.length === 0) return fail(c, 503, "google_unavailable", "Sign in with Google is not configured");
  const body = GoogleSignIn.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "idToken and nonce are required");

  let identity;
  try {
    identity = await verifyGoogleToken(body.data.idToken, c.var.deps.googleKeys, audiences, body.data.nonce);
  } catch {
    return fail(c, 401, "invalid_token", "Google ID token was rejected");
  }

  const db = c.env.DB;
  const user = await signInUser(db, { provider: "google", ...identity }, body.data.name || identity.name);
  const token = await createSession(db, user.id as string, body.data.device ?? null);
  return c.json({ token, user: userOut(user) });
});

auth.post("/logout", requireUser, async (c) => {
  await deleteSession(c.env.DB, c.var.token);
  closeSockets(c, c.var.userId, await sha256Hex(c.var.token));
  return c.body(null, 204);
});
