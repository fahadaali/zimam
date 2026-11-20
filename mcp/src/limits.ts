import { messagePage } from "./consent";
import type { Env } from "./env";

/**
 * Per-IP limits on the open OAuth endpoints, before the OAuth provider sees the request: client
 * registration (anyone may register a client, RFC 7591) and the consent and token endpoints. They
 * use the Workers Rate Limiting bindings in wrangler.jsonc (REGISTER_LIMITER, AUTH_LIMITER), whose
 * periods are 10 or 60 seconds, counted per Cloudflare location and eventually consistent: a brake
 * on floods and scripted abuse, not an exact count. The MCP endpoint itself is not limited here;
 * its calls carry a grant and the API applies the account's own limits.
 *
 * The key is the caller's address from CF-Connecting-IP, which Cloudflare always sets on the
 * internet. Without the binding (wrangler dev, tests) or without that header, nothing is limited.
 * Registration and tokens are asked for by Claude's and ChatGPT's servers, not the person's browser,
 * so many people share one address there: the token endpoint counts per address and client (each
 * connection registers its own client), and registration allows a burst of new connections.
 */
export interface Limit {
  binding: "REGISTER_LIMITER" | "AUTH_LIMITER";
  /** The binding's period in seconds, for Retry-After. Keep it equal to `simple.period` in wrangler.jsonc. */
  period: number;
}

/** The limited routes; anything else passes. */
export const LIMITS: Record<string, Limit> = {
  "/oauth/register": { binding: "REGISTER_LIMITER", period: 60 },
  "/authorize": { binding: "AUTH_LIMITER", period: 60 },
  "/oauth/token": { binding: "AUTH_LIMITER", period: 60 },
};

/** The 429 for a limited request, or null when it may go on. A failing limiter lets it through. */
export async function rateLimit(request: Request, env: Env): Promise<Response | null> {
  const { pathname } = new URL(request.url);
  const limit = LIMITS[pathname];
  if (!limit) return null;
  const limiter = env[limit.binding] as RateLimit | undefined;
  const ip = request.headers.get("CF-Connecting-IP");
  if (!limiter || typeof limiter.limit !== "function" || !ip) return null;
  let success: boolean;
  try {
    ({ success } = await limiter.limit({ key: await keyFor(request, pathname, ip) }));
  } catch (error) {
    console.error(`rate limiter ${limit.binding} failed:`, (error as Error).message);
    return null;
  }
  return success ? null : tooManyRequests(request, pathname, limit.period);
}

/** `<path>:<ip>`, and for the token endpoint `:<client_id>` too, from the form or Basic auth. */
async function keyFor(request: Request, pathname: string, ip: string): Promise<string> {
  const key = `${pathname}:${ip}`;
  if (pathname !== "/oauth/token" || request.method !== "POST") return key;
  let clientId = "";
  const basic = request.headers.get("Authorization")?.match(/^Basic\s+(.+)$/i)?.[1];
  try {
    if (basic) clientId = decodeURIComponent(atob(basic).split(":")[0] ?? "");
    else clientId = String((await request.clone().formData()).get("client_id") ?? "");
  } catch {
    /* not a form: the provider answers it; the address alone counts */
  }
  return `${key}:${clientId.slice(0, 200)}`;
}

/**
 * The consent page is a browser page, so it answers in Arabic HTML; registration and the token
 * endpoint answer as OAuth does, in JSON with an error code (RFC 6749 §5.2 shape). There is no
 * standard code for this, so it is "rate_limited"; Retry-After says when to try again.
 */
function tooManyRequests(request: Request, pathname: string, retryAfter: number): Response {
  const headers = new Headers({ "Retry-After": String(retryAfter), "Cache-Control": "no-store" });
  if (pathname === "/authorize") {
    headers.set("Content-Type", "text/html; charset=utf-8");
    const body = messagePage("طلبات كثيرة", "وصلت من شبكتك طلبات كثيرة في وقت قصير. انتظر دقيقة ثم ابدأ الربط من جديد من التطبيق.");
    return new Response(request.method === "HEAD" ? null : body, { status: 429, headers });
  }
  headers.set("Content-Type", "application/json");
  return new Response(
    JSON.stringify({ error: "rate_limited", error_description: `Too many requests from this address; retry after ${retryAfter} seconds.` }),
    { status: 429, headers },
  );
}
