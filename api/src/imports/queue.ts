import { type Row, userOut } from "../data/rows";
import type { Env } from "../env";
import { flatten, Importer, type Item } from "./apply";
import { decodeText } from "./csv";
import {
  CHUNK_SIZE,
  claimJob,
  deleteFiles,
  failJob,
  getJob,
  type ImportDeps,
  type ImportMessage,
  type JobRow,
  MAX_ITEMS,
  MAX_RETRIES,
  markPrepared,
  parsedKey,
  releaseJob,
  saveProgress,
  uploadKey,
} from "./jobs";
import { arabicNumber, ImportError, TransientImportError } from "./model";
import { SOURCES } from "./sources";

export const IMPORT_QUEUE = "zimam-imports";
export const IMPORT_DEAD_LETTER_QUEUE = "zimam-imports-dlq";

/** What is stored in R2 between chunks: the parsed records, so the source is read once. */
interface Prepared {
  items: Item[];
}

const MESSAGES = {
  internal: "تعذّر إكمال الاستيراد بسبب خطأ في الخادم. ما استُورد قبل الخطأ بقي، وإعادة الاستيراد تكمل الباقي دون تكرار.",
  sourceUnavailable: "تعذّر الوصول إلى المصدر بعد عدة محاولات. أعد المحاولة لاحقاً؛ ما استُورد قبلها لن يتكرر.",
  fileMissing: "لم يعد الملف المرفوع موجوداً. ارفعه مرة أخرى.",
  tokenMissing: "انتهى طلب الاستيراد قبل أن يبدأ. أدخل رمز الوصول مرة أخرى.",
  nothing: "لم نجد في البيانات مهاماً أو مشاريع لاستيرادها.",
  tooMany: `البيانات أكبر من حد الاستيراد الواحد (${arabicNumber(MAX_ITEMS)} عنصر). قسّمها على أكثر من ملف.`,
  unreadable: (label: string) => `تعذّرت قراءة الملف. تأكد أنه ملف التصدير من ${label} دون تعديل، ثم ارفعه مرة أخرى.`,
};

type Outcome = { kind: "ack" } | { kind: "wait"; seconds: number };

function isImportMessage(body: unknown): body is ImportMessage {
  const m = body as ImportMessage;
  return !!m && typeof m.jobId === "string" && Number.isInteger(m.cursor) && m.cursor >= 0;
}

/**
 * The `queue()` handler for both import queues. One message writes one chunk of a
 * job, then sends the message for the next chunk.
 *
 * - `ImportError` (bad file, rejected token): the job fails with its Arabic text; no retry.
 * - Anything else (provider down, D1 error): the message is retried with backoff, up
 *   to `MAX_RETRIES`; the last attempt fails the job instead of retrying.
 * - The dead-letter queue gets what crashed past its retries; the job is failed there.
 */
export async function handleImportBatch(batch: MessageBatch<unknown>, env: Env, deps: ImportDeps) {
  for (const message of batch.messages) {
    if (!isImportMessage(message.body)) {
      message.ack();
      continue;
    }
    const body = message.body;
    if (batch.queue === IMPORT_DEAD_LETTER_QUEUE) {
      await failDeadLetter(env.DB, deps, body);
      message.ack();
      continue;
    }
    try {
      const outcome = await runImportStep(env.DB, deps, body);
      if (outcome.kind === "wait") message.retry({ delaySeconds: outcome.seconds });
      else message.ack();
    } catch (error) {
      // Our own transient messages (endpoint and status) only: others could echo what the user sent.
      const reason = error instanceof TransientImportError ? error.message : error instanceof Error ? error.name : "error";
      console.error(`import ${body.jobId} chunk ${body.cursor} attempt ${message.attempts} failed: ${reason}`);
      await releaseJob(env.DB, body.jobId).catch(() => {});
      if (message.attempts > MAX_RETRIES) {
        const unavailable = error instanceof TransientImportError;
        await failJob(env.DB, deps.files, body.jobId, unavailable ? "source_unavailable" : "internal", unavailable ? MESSAGES.sourceUnavailable : MESSAGES.internal);
        message.ack();
      } else {
        message.retry({ delaySeconds: retryDelay(message.attempts, error) });
      }
    }
  }
}

/** Seconds before retrying: 10, 30, 90, or what the provider asked (Retry-After), at most 15 minutes. */
export function retryDelay(attempts: number, error: unknown): number {
  const asked = error instanceof TransientImportError ? (error.retryAfter ?? 0) : 0;
  return Math.min(Math.max(asked, 10 * 3 ** (attempts - 1)), 900);
}

/**
 * A message that crashed the consumer past its retries. Fails the job only when it is the chunk
 * the job is at. One behind is a duplicate. One ahead was sent by a chunk whose progress is not
 * saved yet, and spent its retries waiting (each wait counts as one): that chunk is still alive,
 * and sends a fresh copy when it saves, or fails the job itself.
 */
async function failDeadLetter(db: D1Database, deps: ImportDeps, body: ImportMessage) {
  const job = await getJob(db, body.jobId);
  if (!job || job.processed !== body.cursor) return;
  if (job.lease_until !== null && job.lease_until > Date.now()) return;
  await failJob(db, deps.files, job.id, "internal", MESSAGES.internal);
}

/** Writes the chunk at `message.cursor`. Exported for tests. */
export async function runImportStep(db: D1Database, deps: ImportDeps, message: ImportMessage, now = Date.now()): Promise<Outcome> {
  const job = await getJob(db, message.jobId);
  if (!job) {
    // Deleted with the account: drop its files.
    await deleteFiles(deps.files, message.jobId);
    return { kind: "ack" };
  }
  if (job.status === "done" || job.status === "failed") return { kind: "ack" };
  // A duplicate of a chunk already written.
  if (job.processed > message.cursor) return { kind: "ack" };
  // The previous chunk's progress is not saved yet.
  if (job.processed < message.cursor) return { kind: "wait", seconds: 5 };
  if (!(await claimJob(db, job.id, message.cursor, now))) {
    const left = Math.ceil(((job.lease_until ?? now) - now) / 1000);
    return { kind: "wait", seconds: Math.min(Math.max(left, 5), 300) };
  }

  let prepared: Prepared;
  try {
    prepared = job.file_key === parsedKey(job.id) ? await readPrepared(deps, job) : await prepare(db, deps, job, message.token);
  } catch (error) {
    if (error instanceof ImportError) {
      await failJob(db, deps.files, job.id, error.code, error.arabic);
      return { kind: "ack" };
    }
    throw error;
  }

  const total = prepared.items.length;
  const slice = prepared.items.slice(message.cursor, message.cursor + CHUNK_SIZE);
  const result = await new Importer(db, job.user_id, SOURCES[job.source].refSource).apply(slice, now);
  const processed = message.cursor + slice.length;
  // The next message first: if saving fails after it, this chunk is retried and the
  // extra next message is dropped as a duplicate. The reverse could lose the job.
  if (processed < total) await deps.enqueue({ jobId: job.id, cursor: processed });
  await saveProgress(db, { ...job, total }, message.cursor, processed, result);
  if (processed >= total) await deleteFiles(deps.files, job.id);
  return { kind: "ack" };
}

async function readPrepared(deps: ImportDeps, job: JobRow): Promise<Prepared> {
  const object = await deps.files.get(parsedKey(job.id));
  if (!object) throw new ImportError("file_missing", MESSAGES.fileMissing);
  return (await object.json()) as Prepared;
}

/** Reads the source once (the upload or the provider's API), parses it, and stores the records in R2. */
async function prepare(db: D1Database, deps: ImportDeps, job: JobRow, token: string | undefined): Promise<Prepared> {
  const source = SOURCES[job.source];
  const user = await db.prepare(`SELECT * FROM users WHERE id = ?`).bind(job.user_id).first<Row>();
  const ctx = { timeZone: user ? userOut(user).settings.timeZone : "Asia/Riyadh", fileName: job.file_name, fetch: deps.fetch };

  let bundle;
  if (source.input === "file") {
    const upload = await deps.files.get(uploadKey(job.id));
    if (!upload) throw new ImportError("file_missing", MESSAGES.fileMissing);
    const text = decodeText(await upload.arrayBuffer());
    try {
      bundle = source.parse(text, ctx);
    } catch (error) {
      if (error instanceof ImportError) throw error;
      console.error(`import ${job.id}: ${source.id} parser failed: ${error instanceof Error ? error.name : "error"}`);
      throw new ImportError("invalid_file", MESSAGES.unreadable(source.label));
    }
  } else {
    if (!token) throw new ImportError("token_missing", MESSAGES.tokenMissing);
    bundle = await source.load(token, ctx);
  }

  const items = flatten(bundle);
  if (items.length === 0) throw new ImportError("nothing_to_import", MESSAGES.nothing);
  if (items.length > MAX_ITEMS) throw new ImportError("too_many_items", MESSAGES.tooMany);
  const prepared: Prepared = { items };
  await deps.files.put(parsedKey(job.id), JSON.stringify(prepared), { httpMetadata: { contentType: "application/json" } });
  await markPrepared(db, job.id, parsedKey(job.id), items.length, bundle.warnings);
  await deps.files.delete(uploadKey(job.id));
  return prepared;
}
