import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { app, uuid } from "./helpers";

/**
 * Every route answers 401 without a session, except the few that are public by design. Walks the
 * app's own route table, so a route added later without `requireUser` fails here.
 */
const PUBLIC = new Set([
  "GET /health",
  "POST /v1/auth/apple",
  "POST /v1/auth/google",
  // The WebSocket signs in itself, with a ticket or a bearer token (src/routes/realtime.ts).
  "GET /v1/realtime",
  // The providers return without a Zimam session: the single-use state names the user.
  "GET /v1/imports/oauth/:source/callback",
  "POST /v1/imports/oauth/trello/callback",
  // App Store Server Notifications: only a pointer, fetched again from Apple.
  "POST /v1/subscriptions/apple/notifications",
]);

const METHODS = new Set(["GET", "POST", "PUT", "PATCH", "DELETE"]);

describe("Route authentication", () => {
  const routes = [
    ...new Map(
      app.routes.filter((r) => METHODS.has(r.method) && r.path.startsWith("/v1/")).map((r) => [`${r.method} ${r.path}`, r]),
    ).values(),
  ];

  it("finds the routes", () => {
    expect(routes.length).toBeGreaterThan(40);
  });

  it("answers 401 without a session on every route that is not public", async () => {
    const open: string[] = [];
    for (const { method, path } of routes) {
      if (PUBLIC.has(`${method} ${path}`)) continue;
      const url = path.replace(/:source/g, "notion").replace(/:[A-Za-z]+/g, uuid());
      for (const suffix of ["", "/"]) {
        const response = await app.fetch(
          new Request(`https://api.zimam.test${url}${suffix}`, {
            method,
            headers: method === "GET" || method === "DELETE" ? {} : { "Content-Type": "application/json" },
            body: method === "GET" || method === "DELETE" ? undefined : "{}",
          }),
          env,
        );
        // A trailing slash may not route at all (404); it must never reach a handler without a user.
        if (response.status !== 401 && !(suffix === "/" && response.status === 404)) {
          open.push(`${method} ${path}${suffix} → ${response.status}`);
        }
      }
    }
    expect(open).toEqual([]);
  });
});
