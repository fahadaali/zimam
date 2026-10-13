import { Hono } from "hono";
import { sha256Hex } from "../auth/crypto";
import { resolveSession } from "../auth/sessions";
import { fail } from "../http";
import { SESSION_HEADER } from "../realtime/channel";
import { issueTicket, redeemTicket } from "../realtime/tickets";
import type { AppEnv } from "../types";

export const realtime = new Hono<AppEnv>();

/** POST /v1/realtime/ticket — a single-use ticket for opening the socket from a browser. */
realtime.post("/ticket", async (c) => {
  const { ticket, expiresAt } = await issueTicket(c.env.DB, c.var.userId, await sha256Hex(c.var.token));
  return c.json({ ticket, expiresAt });
});

/**
 * GET /v1/realtime — the WebSocket. Signed in with `?ticket=` (browsers) or
 * `Authorization: Bearer` (the Apple app). The server sends only
 * `{"type":"changed","seq":N}`; the client pulls when N is past its cursor.
 */
realtime.get("/", async (c) => {
  if (c.req.header("Upgrade")?.toLowerCase() !== "websocket") {
    return fail(c, 426, "upgrade_required", "Open this endpoint as a WebSocket");
  }
  // Browsers send Origin; the Apple app does not. Only the web app's origins may connect.
  const origin = c.req.header("Origin");
  if (origin && !c.env.ALLOWED_ORIGINS.split(",").map((o) => o.trim()).includes(origin)) {
    return fail(c, 403, "forbidden", "Origin not allowed");
  }

  let who: { userId: string; sessionHash: string } | null = null;
  const ticket = c.req.query("ticket");
  const header = c.req.header("Authorization") ?? "";
  if (ticket) {
    who = await redeemTicket(c.env.DB, ticket);
  } else if (header.startsWith("Bearer ")) {
    const token = header.slice(7).trim();
    const userId = await resolveSession(c.env.DB, token);
    if (userId) who = { userId, sessionHash: await sha256Hex(token) };
  }
  if (!who) return fail(c, 401, "unauthorized", "Sign in required");

  return c.env.USER_CHANNEL.getByName(who.userId).fetch("https://user-channel/connect", {
    headers: { Upgrade: "websocket", [SESSION_HEADER]: who.sessionHash },
  });
});
