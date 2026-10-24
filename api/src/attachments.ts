import type { Env } from "./env";
import type { Plan } from "./subscriptions/entitlements";

/**
 * Task attachments: the rules, the storage quota, and removing deleted files from R2.
 * Routes in src/routes/attachments.ts; see api/DEVELOPMENT.md, «المرفقات».
 */

const MB = 1024 * 1024;

/** One file. Workers accept larger bodies, but the app and the browser hold the file in memory. */
export const MAX_ATTACHMENT_BYTES = 25 * MB;

/** Files on one task, so a single task cannot hold the whole quota in small pieces. */
export const MAX_ATTACHMENTS_PER_TASK = 100;

/** Storage per uploader by plan, in MB, when the vars are not set. */
export const DEFAULT_QUOTA_MB: Record<Plan["plan"], number> = { free: 1024, pro: 10 * 1024 };

/**
 * The files people may attach, by extension, with the type the server stores and serves.
 * The client's Content-Type is not trusted: a file is what its extension says, and nothing
 * that a browser would run (HTML, SVG, scripts) is on the list.
 */
export const ATTACHMENT_TYPES: Readonly<Record<string, string>> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".heic": "image/heic",
  ".heif": "image/heif",
  ".pdf": "application/pdf",
  ".txt": "text/plain; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".csv": "text/csv; charset=utf-8",
  ".rtf": "application/rtf",
  ".doc": "application/msword",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".xls": "application/vnd.ms-excel",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".ppt": "application/vnd.ms-powerpoint",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
};

/** Control characters, shown as spaces. */
const CONTROL = /[\u0000-\u001f\u007f]/g;
/** Bidi marks and overrides, which could make a name read as another (an .exe shown as a .pdf). */
const BIDI = /[\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;

/** The name shown and offered on download: the last path part, cleaned, at most 200 characters. */
export function cleanFileName(raw: string): string {
  const base = raw.split(/[\\/]/).pop() ?? "";
  const cleaned = base.replace(BIDI, "").replace(CONTROL, " ").replace(/\s+/g, " ").trim();
  if (cleaned.length <= 200) return cleaned;
  // Keep the extension when shortening.
  const ext = extensionOf(cleaned);
  return cleaned.slice(0, 200 - ext.length).trimEnd() + ext;
}

export function extensionOf(name: string): string {
  return name.match(/\.[^.\s]{1,10}$/)?.[0]?.toLowerCase() ?? "";
}

/**
 * The stored type and the name for an upload, or null when the type is not allowed. A name
 * without an extension (pasted images) takes the extension of an allowed client type.
 */
export function classify(rawName: string, clientType: string): { fileName: string; contentType: string } | null {
  let fileName = cleanFileName(rawName);
  let ext = extensionOf(fileName);
  if (!ext) {
    const type = clientType.split(";")[0]!.trim().toLowerCase();
    ext = Object.keys(ATTACHMENT_TYPES).find((e) => ATTACHMENT_TYPES[e]!.split(";")[0] === type) ?? "";
    if (!ext) return null;
    fileName = `${fileName || "ملف"}${ext}`;
  }
  const contentType = ATTACHMENT_TYPES[ext];
  if (!contentType) return null;
  if (fileName === ext) fileName = `ملف${ext}`;
  return { fileName, contentType };
}

/** `Content-Disposition` with an ASCII fallback and the UTF-8 name (RFC 6266, 8187). */
export function contentDisposition(fileName: string): string {
  const ascii = fileName.replace(/[^\x20-\x7e]/g, "_").replace(/["\\%]/g, "_") || "file";
  const encoded = encodeURIComponent(fileName).replace(/['()*]/g, (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`);
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encoded}`;
}

/** The R2 key: the attachment id only, so names never reach storage logs. */
export const attachmentKey = (id: string) => `attachments/${id}`;

// MARK: Quota

type QuotaVars = Pick<Env, "ATTACHMENT_QUOTA_MB_FREE" | "ATTACHMENT_QUOTA_MB_PRO">;

/** Bytes an uploader may keep on the plan whose limits apply (`limitsPlan`). */
export function storageLimit(env: QuotaVars, plan: Plan["plan"]): number {
  const text = (plan === "pro" ? env.ATTACHMENT_QUOTA_MB_PRO : env.ATTACHMENT_QUOTA_MB_FREE)?.trim() ?? "";
  const mb = /^\d+$/.test(text) ? Number.parseInt(text, 10) : DEFAULT_QUOTA_MB[plan];
  return mb * MB;
}

/**
 * Bytes of live attachments the user pays for: their own uploads on tasks they still see, and the
 * uploads they now own on their projects' and inbox tasks after the uploader lost sight of them
 * (left or was removed from the project, or the task moved). The owner can delete those files, the
 * uploader no longer can, so they count against the owner. Three parts, each read through an index
 * (the uploader's, the owner's projects, the owner's inbox tasks), not a scan of every attachment.
 */
export async function storageUsed(db: D1Database, userId: string): Promise<number> {
  const row = await db
    .prepare(
      `SELECT COALESCE(SUM(size), 0) AS used FROM (
         SELECT a.size FROM attachments a
         WHERE a.user_id = ?1 AND a.deleted_at IS NULL AND (
           (a.project_id IS NULL AND EXISTS (SELECT 1 FROM tasks t WHERE t.id = a.task_id AND t.owner_id = ?1))
           OR EXISTS (SELECT 1 FROM project_members m WHERE m.project_id = a.project_id AND m.user_id = ?1))
         UNION ALL
         SELECT a.size FROM project_members o CROSS JOIN attachments a ON a.project_id = o.project_id
         WHERE o.user_id = ?1 AND o.role = 'owner' AND a.deleted_at IS NULL AND a.user_id <> ?1
           AND NOT EXISTS (SELECT 1 FROM project_members m WHERE m.project_id = a.project_id AND m.user_id = a.user_id)
         UNION ALL
         SELECT a.size FROM tasks t CROSS JOIN attachments a ON a.task_id = t.id
         WHERE t.owner_id = ?1 AND t.project_id IS NULL AND a.project_id IS NULL AND a.deleted_at IS NULL AND a.user_id <> ?1)`,
    )
    .bind(userId)
    .first<{ used: number }>();
  return row?.used ?? 0;
}

// MARK: Removing files

/** D1 allows 100 bound parameters per statement. */
const CHUNK = 90;

/**
 * Removes from R2 the files of deleted attachments (a deleted task, project or account, or
 * DELETE /v1/attachments/:id that could not reach R2), then clears their `r2_key`. Runs with
 * every cron (src/index.ts) and after an account is deleted. Never throws: a file left over is
 * removed on the next run. Returns how many files went.
 */
export async function purgeAttachments(db: D1Database, bucket: R2Bucket, limit = 500): Promise<number> {
  try {
    const { results } = await db
      .prepare(`SELECT id, r2_key FROM attachments WHERE deleted_at IS NOT NULL AND r2_key IS NOT NULL LIMIT ?`)
      .bind(limit)
      .all<{ id: string; r2_key: string }>();
    for (let i = 0; i < results.length; i += CHUNK) {
      const chunk = results.slice(i, i + CHUNK);
      await bucket.delete(chunk.map((r) => r.r2_key));
      await db
        .prepare(`UPDATE attachments SET r2_key = NULL WHERE id IN (${chunk.map(() => "?").join(",")})`)
        .bind(...chunk.map((r) => r.id))
        .run();
    }
    return results.length;
  } catch (error) {
    console.error("attachments: purge failed", error instanceof Error ? error.name : "error");
    return 0;
  }
}
