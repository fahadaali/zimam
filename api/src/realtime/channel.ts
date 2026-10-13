import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env";

/** Carries the hash of the session a socket was opened with, from the Worker to the channel. */
export const SESSION_HEADER = "X-Zimam-Session";

/** Close code for a socket whose session ended (sign-out, account deletion): clients stop reconnecting. */
export const SIGNED_OUT = 4001;

/** Enough for every device and tab of one person; past it the oldest socket makes room. */
const MAX_SOCKETS = 32;

const sessionTag = (sessionHash: string) => `s:${sessionHash}`;

/**
 * One per user (named by the user id): holds that user's open WebSockets and tells
 * them when something they can see changed. It only nudges; the change log and
 * `GET /v1/sync` stay the source of truth, so a missed message costs nothing but time.
 *
 * Uses the WebSocket Hibernation API: between messages the object is evicted from
 * memory and the sockets stay open. Clients send "ping" to keep proxies from closing
 * an idle socket, and the runtime answers "pong" without waking the object.
 */
export class UserChannel extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /** Accepts a socket. Reached only through `GET /v1/realtime`, after it checked the session. */
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }
    const sessionHash = request.headers.get(SESSION_HEADER);
    if (!sessionHash) return new Response("Missing session", { status: 400 });

    const open = this.ctx.getWebSockets();
    for (const old of open.slice(0, Math.max(0, open.length - MAX_SOCKETS + 1))) {
      try {
        old.close(1008, "too many connections");
      } catch {
        /* already closing */
      }
    }

    const [client, server] = Object.values(new WebSocketPair()) as [WebSocket, WebSocket];
    this.ctx.acceptWebSocket(server, [sessionTag(sessionHash)]);
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Sends `{"type":"changed","seq"}` to every open socket; returns how many got it. */
  notify(seq: number): number {
    const message = JSON.stringify({ type: "changed", seq });
    let sent = 0;
    for (const socket of this.ctx.getWebSockets()) {
      try {
        socket.send(message);
        sent++;
      } catch {
        /* closing; the client reconnects and pulls */
      }
    }
    return sent;
  }

  /** Closes the sockets opened with one session (sign-out), or all of them (account deletion). */
  close(sessionHash: string | null): void {
    const sockets = sessionHash ? this.ctx.getWebSockets(sessionTag(sessionHash)) : this.ctx.getWebSockets();
    for (const socket of sockets) {
      try {
        socket.close(SIGNED_OUT, "signed out");
      } catch {
        /* already closed */
      }
    }
  }

  /** Clients only send "ping", which the auto-response answers; anything else is ignored. */
  override webSocketMessage(): void {}

  override webSocketClose(socket: WebSocket, code: number, reason: string): void {
    try {
      socket.close(code, reason);
    } catch {
      /* reserved codes (1005, 1006) cannot be echoed; the socket is closed either way */
    }
  }

  override webSocketError(socket: WebSocket): void {
    try {
      socket.close(1011, "error");
    } catch {
      /* already closed */
    }
  }
}
