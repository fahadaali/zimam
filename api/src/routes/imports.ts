import { type Context, Hono } from "hono";
import { z } from "zod";
import { fail, readJson } from "../http";
import {
  activeJob,
  failJob,
  getUserJob,
  type ImportDeps,
  importsFromEnv,
  insertJob,
  jobOut,
  listUserJobs,
  MAX_UPLOAD_BYTES,
  uploadKey,
} from "../imports/jobs";
import { isOAuthSource, oauthAvailable } from "../imports/oauth";
import { isSourceId, SOURCES } from "../imports/sources";
import { requirePro } from "../subscriptions/entitlements";
import type { AppEnv } from "../types";

/** Imports from other apps. The work happens on the zimam-imports queue (src/imports/queue.ts). */
export const imports = new Hono<AppEnv>();

const deps = (c: Context<AppEnv>): ImportDeps => c.var.deps.imports?.(c.env) ?? importsFromEnv(c.env);

const TokenBody = z.object({
  source: z.string(),
  /** A personal API token the user pasted. Sent on in the queue message only; never stored or logged. */
  token: z.string().trim().min(8).max(500).regex(/^\S+$/),
});

/**
 * GET /v1/imports/sources — what can be imported and how. `available` is false for an OAuth
 * source whose secrets are not set on this deployment: the apps show it greyed out.
 */
imports.get("/sources", (c) =>
  c.json({
    maxFileBytes: MAX_UPLOAD_BYTES,
    sources: Object.values(SOURCES).map((s) => ({
      id: s.id,
      label: s.label,
      input: s.input,
      extensions: s.input === "file" ? s.extensions : undefined,
      available: isOAuthSource(s.id) ? oauthAvailable(c.env, s.id) : true,
    })),
  }),
);

/**
 * POST /v1/imports — starts an import; 202 with the job.
 * - A file: multipart/form-data with `source` and `file` (up to MAX_UPLOAD_BYTES).
 * - A token: JSON `{ source: "todoist-api", token }`.
 * One import at a time per user (409 import_in_progress).
 * Every source here needs «زمام الاحترافية» when enforced (403 pro_required); Apple
 * Reminders, the free one, is imported on the device and never comes here.
 */
imports.post("/", requirePro, async (c) => {
  const userId = c.var.userId;
  const { enqueue, files } = deps(c);
  const contentType = c.req.header("Content-Type") ?? "";
  const id = crypto.randomUUID();
  let job: { source: keyof typeof SOURCES; fileName: string | null; fileSize: number | null; fileKey: string | null };
  let token: string | undefined;
  let upload: File | null = null;

  if (contentType.startsWith("multipart/form-data")) {
    // Refuse before reading the body when the client says it is too large.
    const length = Number(c.req.header("Content-Length") ?? 0);
    if (length > MAX_UPLOAD_BYTES + 64 * 1024) return tooLarge(c);
    let form: FormData;
    try {
      form = await c.req.formData();
    } catch {
      return fail(c, 400, "invalid", "Send multipart/form-data with source and file");
    }
    const source = form.get("source");
    const file = form.get("file");
    if (!isSourceId(source)) return fail(c, 400, "invalid_source", "Unknown import source");
    const spec = SOURCES[source];
    if (spec.input !== "file") return fail(c, 400, "invalid_source", "This source takes a token, not a file");
    if (!(file instanceof File)) return fail(c, 400, "invalid", "file is required");
    if (file.size > MAX_UPLOAD_BYTES) return tooLarge(c);
    if (file.size === 0) return fail(c, 400, "empty_file", "The file is empty");
    const name = file.name.split(/[\\/]/).pop()?.slice(0, 255) || null;
    const extension = name?.match(/\.[^.]+$/)?.[0]?.toLowerCase();
    if (extension && !spec.extensions.includes(extension)) {
      return fail(c, 400, "invalid_file_type", `Expected ${spec.extensions.join(", ")}`);
    }
    upload = file;
    job = { source, fileName: name, fileSize: file.size, fileKey: uploadKey(id) };
  } else {
    const raw = (await readJson(c)) as { source?: unknown } | undefined;
    if (!isSourceId(raw?.source)) return fail(c, 400, "invalid_source", "Unknown import source");
    if (SOURCES[raw.source].input === "file") return fail(c, 400, "invalid", "Upload this source's file as multipart/form-data");
    if (SOURCES[raw.source].input === "oauth") return fail(c, 400, "invalid_source", "This source connects through GET /v1/imports/oauth/:source/start");
    const body = TokenBody.safeParse(raw);
    if (!body.success) return fail(c, 400, "invalid", "token is required");
    token = body.data.token;
    job = { source: raw.source, fileName: null, fileSize: null, fileKey: null };
  }

  if (await activeJob(c.env.DB, userId)) return fail(c, 409, "import_in_progress", "Another import is still running");

  if (upload) {
    await files.put(uploadKey(id), await upload.arrayBuffer(), {
      httpMetadata: { contentType: upload.type || "application/octet-stream" },
    });
  }
  await insertJob(c.env.DB, { id, userId, ...job });
  try {
    await enqueue({ jobId: id, cursor: 0, token });
  } catch (error) {
    console.error(`import ${id}: enqueue failed: ${error instanceof Error ? error.name : "error"}`);
    await failJob(c.env.DB, files, id, "unavailable", "تعذّر بدء الاستيراد الآن. أعد المحاولة بعد قليل.");
    return fail(c, 503, "import_unavailable", "Could not start the import");
  }
  const row = await getUserJob(c.env.DB, userId, id);
  return c.json({ job: jobOut(row!) }, 202);
});

/** GET /v1/imports — the user's latest imports, newest first. */
imports.get("/", async (c) => {
  const jobs = await listUserJobs(c.env.DB, c.var.userId);
  return c.json({ jobs: jobs.map(jobOut) });
});

/** GET /v1/imports/:id — status, progress, counts and errors; 404 for another user's job. */
imports.get("/:id", async (c) => {
  const id = z.uuid().safeParse(c.req.param("id"));
  const row = id.success ? await getUserJob(c.env.DB, c.var.userId, id.data.toLowerCase()) : null;
  if (!row) return fail(c, 404, "not_found", "Import not found");
  return c.json({ job: jobOut(row) });
});

function tooLarge(c: Context<AppEnv>) {
  return fail(c, 413, "file_too_large", `Files up to ${MAX_UPLOAD_BYTES / (1024 * 1024)} MB`);
}
