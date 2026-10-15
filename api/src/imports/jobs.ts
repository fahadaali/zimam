import type { Env } from "../env";
import type { Counts, CountsByEntity, ItemError } from "./apply";
import type { SourceId } from "./source";

/** Uploads larger than this are refused (413). */
export const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;
/** Records (projects, sections, tasks, reminders) in one import. */
export const MAX_ITEMS = 20_000;
/** Records written per queue message: well inside D1's 1,000 queries per invocation. */
export const CHUNK_SIZE = 50;
/** How long a consumer holds a job while it writes a chunk. */
export const LEASE_MS = 2 * 60_000;
/** Matches `max_retries` of the zimam-imports consumer in wrangler.jsonc. */
export const MAX_RETRIES = 3;
/** A queued or running job not touched for this long no longer blocks a new import. */
export const STALE_JOB_MS = 60 * 60_000;
const MAX_ERRORS = 50;

/** The body of a zimam-imports message. The token is only in the first one, and is never stored. */
export interface ImportMessage {
  jobId: string;
  /** Index of the first record this message writes; equals the job's `processed`. */
  cursor: number;
  token?: string;
}

/** What the import pipeline needs from outside; tests pass fakes. */
export interface ImportDeps {
  enqueue(message: ImportMessage): Promise<void>;
  files: R2Bucket;
  fetch: typeof fetch;
}

export function importsFromEnv(env: Env): ImportDeps {
  return {
    enqueue: async (message) => {
      await env.IMPORTS.send(message, { contentType: "json" });
    },
    files: env.IMPORT_FILES,
    fetch: (input, init) => fetch(input, init),
  };
}

export const uploadKey = (jobId: string) => `uploads/${jobId}`;
export const parsedKey = (jobId: string) => `parsed/${jobId}.json`;

export type JobStatus = "queued" | "running" | "done" | "failed";

export interface JobRow {
  id: string;
  user_id: string;
  source: SourceId;
  status: JobStatus;
  file_name: string | null;
  file_size: number | null;
  file_key: string | null;
  total: number;
  processed: number;
  counts: string;
  errors: string;
  warnings: string;
  error_code: string | null;
  error_message: string | null;
  lease_until: number | null;
  created_at: number;
  updated_at: number;
  finished_at: number | null;
}

export function getJob(db: D1Database, id: string) {
  return db.prepare(`SELECT * FROM import_jobs WHERE id = ?`).bind(id).first<JobRow>();
}

export function getUserJob(db: D1Database, userId: string, id: string) {
  return db.prepare(`SELECT * FROM import_jobs WHERE id = ? AND user_id = ?`).bind(id, userId).first<JobRow>();
}

export async function listUserJobs(db: D1Database, userId: string, limit = 20) {
  const { results } = await db
    .prepare(`SELECT * FROM import_jobs WHERE user_id = ? ORDER BY created_at DESC, id LIMIT ?`)
    .bind(userId, limit)
    .all<JobRow>();
  return results;
}

/** A job of the user's still in progress, if any (stale ones do not count). */
export function activeJob(db: D1Database, userId: string, now = Date.now()) {
  return db
    .prepare(`SELECT id FROM import_jobs WHERE user_id = ? AND status IN ('queued', 'running') AND updated_at > ? LIMIT 1`)
    .bind(userId, now - STALE_JOB_MS)
    .first<{ id: string }>();
}

export async function insertJob(
  db: D1Database,
  job: { id: string; userId: string; source: SourceId; fileName: string | null; fileSize: number | null; fileKey: string | null },
  now = Date.now(),
) {
  await db
    .prepare(
      `INSERT INTO import_jobs (id, user_id, source, status, file_name, file_size, file_key, created_at, updated_at)
       VALUES (?, ?, ?, 'queued', ?, ?, ?, ?, ?)`,
    )
    .bind(job.id, job.userId, job.source, job.fileName, job.fileSize, job.fileKey, now, now)
    .run();
}

/** Takes the job for the chunk at `cursor`; false when another consumer holds it. */
export async function claimJob(db: D1Database, id: string, cursor: number, now = Date.now()): Promise<boolean> {
  const result = await db
    .prepare(
      `UPDATE import_jobs SET status = 'running', lease_until = ?3, updated_at = ?4
       WHERE id = ?1 AND processed = ?2 AND status IN ('queued', 'running') AND (lease_until IS NULL OR lease_until < ?4)`,
    )
    .bind(id, cursor, now + LEASE_MS, now)
    .run();
  return result.meta.changes > 0;
}

export async function releaseJob(db: D1Database, id: string) {
  await db.prepare(`UPDATE import_jobs SET lease_until = NULL WHERE id = ? AND status = 'running'`).bind(id).run();
}

/** Records the parsed data: where it is, how many records, and the parser's warnings. */
export async function markPrepared(db: D1Database, id: string, fileKey: string, total: number, warnings: string[]) {
  await db
    .prepare(`UPDATE import_jobs SET file_key = ?2, total = ?3, warnings = ?4, updated_at = ?5 WHERE id = ?1`)
    .bind(id, fileKey, total, JSON.stringify(warnings.slice(0, MAX_ERRORS)), Date.now())
    .run();
}

export function mergeCounts(a: CountsByEntity, b: CountsByEntity): CountsByEntity {
  const out: CountsByEntity = structuredClone(a);
  for (const [entity, counts] of Object.entries(b) as [keyof CountsByEntity, Counts][]) {
    const target = (out[entity] ??= { created: 0, updated: 0, unchanged: 0, skipped: 0, failed: 0 });
    for (const k of Object.keys(counts) as (keyof Counts)[]) target[k] += counts[k];
  }
  return out;
}

/** Saves a written chunk. Only the consumer at `cursor` can, so a duplicate message cannot count twice. */
export async function saveProgress(
  db: D1Database,
  job: JobRow,
  cursor: number,
  processed: number,
  chunk: { counts: CountsByEntity; errors: ItemError[] },
  now = Date.now(),
): Promise<boolean> {
  const done = processed >= job.total;
  const counts = mergeCounts(JSON.parse(job.counts) as CountsByEntity, chunk.counts);
  const errors = [...(JSON.parse(job.errors) as ItemError[]), ...chunk.errors].slice(0, MAX_ERRORS);
  const result = await db
    .prepare(
      `UPDATE import_jobs SET processed = ?3, counts = ?4, errors = ?5, lease_until = NULL, updated_at = ?6,
         status = CASE WHEN ?7 THEN 'done' ELSE 'running' END,
         finished_at = CASE WHEN ?7 THEN ?6 ELSE NULL END,
         file_key = CASE WHEN ?7 THEN NULL ELSE file_key END
       WHERE id = ?1 AND processed = ?2 AND status = 'running'`,
    )
    .bind(job.id, cursor, processed, JSON.stringify(counts), JSON.stringify(errors), now, done ? 1 : 0)
    .run();
  return result.meta.changes > 0;
}

/** Ends a job as failed with an Arabic message, and deletes its files. What was already written stays. */
export async function failJob(db: D1Database, files: R2Bucket, id: string, code: string, message: string, now = Date.now()) {
  await db
    .prepare(
      `UPDATE import_jobs SET status = 'failed', error_code = ?2, error_message = ?3, lease_until = NULL,
         file_key = NULL, updated_at = ?4, finished_at = ?4
       WHERE id = ?1 AND status IN ('queued', 'running')`,
    )
    .bind(id, code, message, now)
    .run();
  await deleteFiles(files, id);
}

export async function deleteFiles(files: R2Bucket, jobId: string) {
  await files.delete([uploadKey(jobId), parsedKey(jobId)]);
}

const zero = (): Counts => ({ created: 0, updated: 0, unchanged: 0, skipped: 0, failed: 0 });

/** The job as the API returns it. */
export function jobOut(row: JobRow) {
  const byEntity = JSON.parse(row.counts) as CountsByEntity;
  const totals = zero();
  for (const counts of Object.values(byEntity)) {
    for (const k of Object.keys(totals) as (keyof Counts)[]) totals[k] += counts[k];
  }
  return {
    id: row.id,
    source: row.source,
    status: row.status,
    fileName: row.file_name,
    progress: { processed: row.processed, total: row.total },
    counts: { ...totals, byEntity },
    warnings: JSON.parse(row.warnings) as string[],
    errors: JSON.parse(row.errors) as ItemError[],
    error: row.error_code ? { code: row.error_code, message: row.error_message } : null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    finishedAt: row.finished_at,
  };
}
