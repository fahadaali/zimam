import { Hono } from "hono";
import { cors } from "hono/cors";
import { fail } from "./http";
import { requireUser } from "./middleware";
import { devices } from "./push/devices";
import { assistant } from "./routes/assistant";
import { prayers } from "./routes/prayers";
import { attachments } from "./routes/attachments";
import { auth } from "./routes/auth";
import { comments } from "./routes/comments";
import { importOAuth, isOAuthCallback } from "./routes/import-oauth";
import { imports } from "./routes/imports";
import { invites } from "./routes/invites";
import { me } from "./routes/me";
import { members } from "./routes/members";
import { projects } from "./routes/projects";
import { realtime } from "./routes/realtime";
import { subscriptions } from "./routes/subscriptions";
import { sync } from "./routes/sync";
import { tasks } from "./routes/tasks";
import type { AppEnv, Deps } from "./types";

export function createApp(deps: Deps) {
  const app = new Hono<AppEnv>();

  app.use("*", async (c, next) => {
    c.set("deps", deps);
    await next();
  });
  app.use(
    "/v1/*",
    cors({
      origin: (origin, c) => (c.env.ALLOWED_ORIGINS.split(",").map((o: string) => o.trim()).includes(origin) ? origin : null),
      allowHeaders: ["Authorization", "Content-Type"],
      allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE"],
      maxAge: 86_400,
    }),
  );

  app.get("/health", (c) => c.json({ ok: true }));
  app.route("/v1/auth", auth);
  const signedIn = [
    "/v1/me", "/v1/me/*", "/v1/sync", "/v1/projects", "/v1/projects/*",
    "/v1/tasks", "/v1/tasks/*", "/v1/invites/*", "/v1/comments/*", "/v1/assistant/*",
    "/v1/devices/*", "/v1/realtime/ticket", "/v1/imports",
    "/v1/attachments/*", "/v1/prayers",
  ];
  for (const path of signedIn) {
    app.use(path, requireUser);
  }
  // The OAuth providers return to the import callbacks without a session: their state names the user.
  app.use("/v1/imports/*", (c, next) => (isOAuthCallback(c.req.path) ? next() : requireUser(c, next)));
  app.route("/v1/me", me);
  app.route("/v1/sync", sync);
  app.route("/v1/projects", projects);
  app.route("/v1/projects", members);
  app.route("/v1/tasks", tasks);
  app.route("/v1/invites", invites);
  app.route("/v1", comments);
  app.route("/v1", attachments);
  app.route("/v1/assistant", assistant);
  app.route("/v1/prayers", prayers);
  app.route("/v1/devices", devices);
  app.route("/v1/realtime", realtime);
  app.route("/v1/imports/oauth", importOAuth);
  app.route("/v1/imports", imports);
  // Signed-in per route: the App Store's notifications come without a session.
  app.route("/v1/subscriptions", subscriptions);

  app.notFound((c) => fail(c, 404, "not_found", "No such endpoint"));
  app.onError((err, c) => {
    console.error(err);
    return fail(c, 500, "internal", "Something went wrong");
  });
  return app;
}
