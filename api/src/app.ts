import { Hono } from "hono";
import { cors } from "hono/cors";
import { fail } from "./http";
import { requireUser } from "./middleware";
import { auth } from "./routes/auth";
import { me } from "./routes/me";
import { projects } from "./routes/projects";
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
      allowMethods: ["GET", "POST", "PATCH", "DELETE"],
      maxAge: 86_400,
    }),
  );

  app.get("/health", (c) => c.json({ ok: true }));
  app.route("/v1/auth", auth);
  for (const path of ["/v1/me", "/v1/me/*", "/v1/sync", "/v1/projects", "/v1/projects/*", "/v1/tasks", "/v1/tasks/*"]) {
    app.use(path, requireUser);
  }
  app.route("/v1/me", me);
  app.route("/v1/sync", sync);
  app.route("/v1/projects", projects);
  app.route("/v1/tasks", tasks);

  app.notFound((c) => fail(c, 404, "not_found", "No such endpoint"));
  app.onError((err, c) => {
    console.error(err);
    return fail(c, 500, "internal", "Something went wrong");
  });
  return app;
}
