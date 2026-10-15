import { type Context, Hono } from "hono";
import { z } from "zod";
import {
  attachmentKey,
  classify,
  contentDisposition,
  MAX_ATTACHMENT_BYTES,
  MAX_ATTACHMENTS_PER_TASK,
  storageLimit,
  storageUsed,
} from "../attachments";
import { attachmentOut, type Row } from "../data/rows";
import { fail } from "../http";
import { limitsPlan } from "../subscriptions/entitlements";
import type { AppEnv } from "../types";
import { loadVisible } from "./resources";

/**
 * Task attachments, mounted under /v1 (api/DEVELOPMENT.md, «المرفقات»). Whoever can see a task
 * sees and downloads its files; whoever can edit it attaches; the uploader or the project's
 * owner deletes. Metadata reaches devices as change rows (entity 'attachment'); files are
 * fetched on demand from GET /v1/attachments/:id.
 */
export const attachments = new Hono<AppEnv>();

type Ctx = Context<AppEnv>;

const SELECT_WITH_UPLOADER = `SELECT a.*, u.name AS uploader_name FROM attachments a JOIN users u ON u.id = a.user_id`;

const withUploader = (r: Row) => ({ ...attachmentOut(r), uploaderName: (r.uploader_name ?? null) as string | null });

/** A live attachment on a task the user can see, with that task. */
async function loadAttachment(c: Ctx, rawId: string): Promise<{ row: Row; task: Row } | null> {
  const id = z.uuid().safeParse(rawId);
  if (!id.success) return null;
  const row = await c.env.DB.prepare(`SELECT * FROM attachments WHERE id = ?`).bind(id.data.toLowerCase()).first<Row>();
  if (!row || row.deleted_at != null) return null;
  const task = await loadVisible(c, "task", row.task_id as string);
  return task ? { row, task } : null;
}

/** The owner of the task's project, or of the inbox task: may delete anyone's file on it. */
async function ownsTask(c: Ctx, task: Row): Promise<boolean> {
  const projectId = (task.project_id ?? null) as string | null;
  return projectId ? (await c.var.access.role(projectId)) === "owner" : task.owner_id === c.var.userId;
}

function tooLarge(c: Ctx) {
  return fail(c, 413, "file_too_large", `Files up to ${MAX_ATTACHMENT_BYTES / (1024 * 1024)} MB`);
}

/** GET /tasks/:id/attachments — oldest first, with the upload limit and whether this user may attach. */
attachments.get("/tasks/:id/attachments", async (c) => {
  const task = await loadVisible(c, "task", c.req.param("id"));
  if (!task) return fail(c, 404, "not_found", "task not found");
  const { results } = await c.env.DB.prepare(
    `${SELECT_WITH_UPLOADER} WHERE a.task_id = ? AND a.deleted_at IS NULL ORDER BY a.created_at, a.id`,
  )
    .bind(task.id)
    .all<Row>();
  const owner = await ownsTask(c, task);
  return c.json({
    attachments: results.map((r) => ({ ...withUploader(r), canDelete: owner || r.user_id === c.var.userId })),
    maxFileBytes: MAX_ATTACHMENT_BYTES,
    canAdd: await c.var.access.canEditTask(task),
  });
});

/**
 * POST /tasks/:id/attachments — multipart/form-data with `file`. 201 with the attachment.
 * 400 `invalid_file_type`, `empty_file` or `invalid`; 403 for a viewer; 409 `too_many_attachments`;
 * 413 `file_too_large` or `storage_quota_exceeded` (with `limit` and `used` in bytes).
 */
attachments.post("/tasks/:id/attachments", async (c) => {
  // Refuse before reading the body when the client says it is too large.
  if (Number(c.req.header("Content-Length") ?? 0) > MAX_ATTACHMENT_BYTES + 64 * 1024) return tooLarge(c);
  const task = await loadVisible(c, "task", c.req.param("id"));
  if (!task) return fail(c, 404, "not_found", "task not found");
  if (!(await c.var.access.canEditTask(task))) return fail(c, 403, "forbidden", "Cannot attach files to this task");
  if (!(c.req.header("Content-Type") ?? "").startsWith("multipart/form-data")) {
    return fail(c, 400, "invalid", "Send multipart/form-data with file");
  }
  let form: FormData;
  try {
    form = await c.req.formData();
  } catch {
    return fail(c, 400, "invalid", "Send multipart/form-data with file");
  }
  const file = form.get("file");
  if (!(file instanceof File)) return fail(c, 400, "invalid", "file is required");
  if (file.size > MAX_ATTACHMENT_BYTES) return tooLarge(c);
  if (file.size === 0) return fail(c, 400, "empty_file", "The file is empty");
  const kind = classify(file.name, file.type);
  if (!kind) return fail(c, 400, "invalid_file_type", "Images, PDF, text and Office documents only");

  const db = c.env.DB;
  const userId = c.var.userId;
  const count = await db
    .prepare(`SELECT COUNT(*) AS n FROM attachments WHERE task_id = ? AND deleted_at IS NULL`)
    .bind(task.id)
    .first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_ATTACHMENTS_PER_TASK) {
    return fail(c, 409, "too_many_attachments", `Up to ${MAX_ATTACHMENTS_PER_TASK} files on a task`);
  }
  const plan = await limitsPlan(c.env, userId);
  const limit = storageLimit(c.env, plan);
  const used = await storageUsed(db, userId);
  if (used + file.size > limit) {
    const error = { code: "storage_quota_exceeded", message: "Attachment storage is full", limit, used, plan };
    return c.json({ error }, 413);
  }

  const id = crypto.randomUUID();
  const key = attachmentKey(id);
  const now = Date.now();
  await c.env.ATTACHMENTS.put(key, await file.arrayBuffer(), {
    httpMetadata: { contentType: kind.contentType },
    customMetadata: { taskId: task.id as string, userId },
  });
  try {
    // Only while the task is still there: a delete that raced this upload wins.
    const [inserted] = await db.batch([
      db
        .prepare(
          `INSERT INTO attachments (id, task_id, project_id, user_id, file_name, content_type, size, r2_key, created_at, updated_at)
           SELECT ?1, id, project_id, ?2, ?3, ?4, ?5, ?6, ?7, ?7 FROM tasks WHERE id = ?8 AND deleted_at IS NULL`,
        )
        .bind(id, userId, kind.fileName, kind.contentType, file.size, key, now, task.id),
      // Logged to the task's audience, like a comment.
      db
        .prepare(
          `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
           SELECT 'attachment', a.id, t.project_id, CASE WHEN t.project_id IS NULL THEN t.owner_id END, ?2
           FROM attachments a JOIN tasks t ON t.id = a.task_id WHERE a.id = ?1`,
        )
        .bind(id, now),
    ]);
    if (!inserted?.meta.changes) {
      await c.env.ATTACHMENTS.delete(key);
      return fail(c, 404, "not_found", "task not found");
    }
  } catch (error) {
    await c.env.ATTACHMENTS.delete(key).catch(() => undefined);
    throw error;
  }
  const row = await db.prepare(`${SELECT_WITH_UPLOADER} WHERE a.id = ?`).bind(id).first<Row>();
  return c.json({ ...withUploader(row!), canDelete: true }, 201);
});

/**
 * GET /attachments/:id — the file itself, for whoever can see its task. Served as a download
 * with the stored type, never sniffed or run (a sandboxing CSP), and never cached by shared caches.
 */
attachments.get("/attachments/:id", async (c) => {
  const found = await loadAttachment(c, c.req.param("id"));
  if (!found) return fail(c, 404, "not_found", "attachment not found");
  const { row } = found;
  const object = row.r2_key ? await c.env.ATTACHMENTS.get(row.r2_key as string) : null;
  if (!object) return fail(c, 404, "not_found", "attachment not found");
  return new Response(object.body, {
    headers: {
      "Content-Type": row.content_type as string,
      "Content-Length": String(object.size),
      "Content-Disposition": contentDisposition(row.file_name as string),
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "Content-Security-Policy": "default-src 'none'; sandbox",
    },
  });
});

/** DELETE /attachments/:id — the uploader, or the owner of the task's project (or of the inbox task). */
attachments.delete("/attachments/:id", async (c) => {
  const found = await loadAttachment(c, c.req.param("id"));
  if (!found) return fail(c, 404, "not_found", "attachment not found");
  const { row, task } = found;
  const projectId = (task.project_id ?? null) as string | null;
  if (row.user_id !== c.var.userId && !(await ownsTask(c, task))) {
    return fail(c, 403, "forbidden", "Only the uploader or the project owner can delete a file");
  }
  const db = c.env.DB;
  const now = Date.now();
  await db.batch([
    db.prepare(`UPDATE attachments SET deleted_at = ?2, updated_at = ?2 WHERE id = ?1`).bind(row.id, now),
    db
      .prepare(`INSERT INTO changes (entity, entity_id, project_id, user_id, at) VALUES ('attachment', ?, ?, ?, ?)`)
      .bind(row.id, projectId, projectId ? null : task.owner_id, now),
  ]);
  try {
    await c.env.ATTACHMENTS.delete(row.r2_key as string);
    await db.prepare(`UPDATE attachments SET r2_key = NULL WHERE id = ?`).bind(row.id).run();
  } catch (error) {
    // The cron's purge removes it later.
    console.error("attachments: could not delete a file now", error instanceof Error ? error.name : "error");
  }
  return c.body(null, 204);
});
