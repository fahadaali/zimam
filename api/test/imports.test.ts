import { createExecutionContext, createMessageBatch, getQueueResult } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import worker from "../src/index";
import { CHUNK_SIZE, type ImportDeps, type ImportMessage, MAX_UPLOAD_BYTES, parsedKey, uploadKey } from "../src/imports/jobs";
import { TransientImportError } from "../src/imports/model";
import { handleImportBatch, IMPORT_DEAD_LETTER_QUEUE, IMPORT_QUEUE, retryDelay } from "../src/imports/queue";
import googleTasksJson from "./fixtures/imports/google-tasks.json?raw";
import tickTickBackup from "./fixtures/imports/ticktick-backup.csv?raw";
import todoistApiJson from "./fixtures/imports/todoist-api.json?raw";
import todoistTemplate from "./fixtures/imports/todoist-template.csv?raw";
import { call, fakeAi, pullAll, push, signIn, testAppleKeys, testGoogleKeys } from "./helpers";

// MARK: Fakes

/** Messages the API and the consumer sent, delivered by hand with `drain()`. */
let sent: ImportMessage[] = [];
let failEnqueue = false;
let todoist: (url: URL, init?: RequestInit) => Response | Promise<Response>;

const importDeps = (): ImportDeps => ({
  enqueue: async (message) => {
    if (failEnqueue) throw new Error("queue unavailable");
    sent.push(structuredClone(message));
  },
  files: env.IMPORT_FILES,
  fetch: async (input, init) => todoist(new URL(input instanceof Request ? input.url : String(input)), init),
});

const app = createApp({ appleKeys: testAppleKeys, googleKeys: testGoogleKeys, ai: () => fakeAi, appleTokens: () => null, imports: importDeps });

beforeEach(() => {
  sent = [];
  failEnqueue = false;
  todoist = () => new Response("not stubbed", { status: 500 });
});

// MARK: Helpers

interface Job {
  id: string;
  source: string;
  status: string;
  fileName: string | null;
  progress: { processed: number; total: number };
  counts: { created: number; updated: number; unchanged: number; skipped: number; failed: number; byEntity: Record<string, Record<string, number>> };
  warnings: string[];
  errors: { entity: string; title: string; message: string }[];
  error: { code: string; message: string } | null;
}

async function request(method: string, path: string, o: { token?: string; json?: unknown; form?: FormData } = {}) {
  const headers = new Headers();
  if (o.token) headers.set("Authorization", `Bearer ${o.token}`);
  let body: BodyInit | undefined;
  if (o.json !== undefined) {
    headers.set("Content-Type", "application/json");
    body = JSON.stringify(o.json);
  } else if (o.form) {
    body = o.form;
  }
  const response = await app.fetch(new Request(`https://api.zimam.test${path}`, { method, headers, body }), env);
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

async function upload(token: string, source: string, content: string | Uint8Array, name: string) {
  const form = new FormData();
  form.set("source", source);
  form.set("file", new File([content], name, { type: name.endsWith(".json") ? "application/json" : "text/csv" }));
  return request("POST", "/v1/imports", { token, form });
}

async function deliver(message: ImportMessage, attempts = 1, queue = IMPORT_QUEUE) {
  const batch = createMessageBatch<ImportMessage>(queue, [{ id: crypto.randomUUID(), timestamp: Date.now(), attempts, body: message }]);
  const ctx = createExecutionContext();
  await handleImportBatch(batch, env, importDeps());
  return getQueueResult(batch, ctx);
}

/** Delivers every queued message, and the ones they send, until the queue is empty. */
async function drain() {
  for (let i = 0; sent.length > 0; i++) {
    if (i > 100) throw new Error("the import never finished");
    const result = await deliver(sent.shift()!);
    expect(result.retryMessages).toEqual([]);
  }
}

async function getJob(token: string, id: string): Promise<Job> {
  const res = await request("GET", `/v1/imports/${id}`, { token });
  expect(res.status).toBe(200);
  return res.body.job;
}

/** Uploads a file and runs the import to the end. */
async function importFile(token: string, source: string, content: string | Uint8Array, name: string): Promise<Job> {
  const res = await upload(token, source, content, name);
  expect(res.status).toBe(202);
  await drain();
  return getJob(token, res.body.job.id);
}

async function liveTasks(userId: string) {
  const { results } = await env.DB.prepare(
    `SELECT t.* FROM tasks t LEFT JOIN projects p ON p.id = t.project_id
     WHERE t.deleted_at IS NULL AND (t.owner_id = ?1 OR p.owner_id = ?1) ORDER BY t.title`,
  )
    .bind(userId)
    .all<Record<string, unknown>>();
  return results;
}

const r2Keys = async (jobId: string) =>
  (await Promise.all([env.IMPORT_FILES.head(uploadKey(jobId)), env.IMPORT_FILES.head(parsedKey(jobId))])).filter(Boolean).length;

const todoistData = JSON.parse(todoistApiJson) as Record<string, unknown[]>;
const todoistServer = (token: string, seen: string[] = []) => (url: URL, init?: RequestInit) => {
  seen.push(url.pathname);
  if (new Headers(init?.headers).get("Authorization") !== `Bearer ${token}`) return new Response("Forbidden", { status: 401 });
  const name = url.pathname.replace("/rest/v2/", "");
  return Response.json(todoistData[name] ?? []);
};

// MARK: Tests

describe("Imports API", () => {
  it("lists the sources", async () => {
    const { token } = await signIn();
    const res = await request("GET", "/v1/imports/sources", { token });
    expect(res.status).toBe(200);
    expect(res.body.maxFileBytes).toBe(MAX_UPLOAD_BYTES);
    expect(res.body.sources.map((s: { id: string; input: string }) => [s.id, s.input])).toEqual([
      ["todoist-oauth", "oauth"],
      ["todoist-csv", "file"],
      ["todoist-api", "token"],
      ["ticktick-csv", "file"],
      ["google-tasks-api", "oauth"],
      ["google-tasks", "file"],
      ["csv", "file"],
      ["google-calendar", "oauth"],
      ["microsoft-todo", "oauth"],
      ["notion", "oauth"],
      ["trello", "oauth"],
      ["asana", "oauth"],
      ["ticktick-api", "oauth"],
    ]);
  });

  it("imports a Todoist template through the queue, with change rows devices pull", async () => {
    const { token, userId } = await signIn();
    const res = await upload(token, "todoist-csv", todoistTemplate, "زواج فهد.csv");
    expect(res.status).toBe(202);
    const created: Job = res.body.job;
    expect(created).toMatchObject({ source: "todoist-csv", status: "queued", fileName: "زواج فهد.csv", progress: { processed: 0, total: 0 } });
    expect(sent).toEqual([{ jobId: created.id, cursor: 0 }]);
    expect(await env.IMPORT_FILES.head(uploadKey(created.id))).not.toBeNull();

    await drain();
    const job = await getJob(token, created.id);
    expect(job.status).toBe("done");
    expect(job.progress).toEqual({ processed: 8, total: 8 });
    expect(job.counts).toMatchObject({ created: 8, updated: 0, unchanged: 0, skipped: 0, failed: 0 });
    expect(job.counts.byEntity).toEqual({
      project: { created: 1, updated: 0, unchanged: 0, skipped: 0, failed: 0 },
      section: { created: 2, updated: 0, unchanged: 0, skipped: 0, failed: 0 },
      task: { created: 5, updated: 0, unchanged: 0, skipped: 0, failed: 0 },
    });
    expect(job.warnings).toHaveLength(2);
    // Files are deleted once the job ends.
    expect(await r2Keys(job.id)).toBe(0);

    const pulled = await pullAll(token);
    const entities = pulled.changes.map((c) => c.entity);
    expect(entities.filter((e) => e === "project")).toHaveLength(1);
    expect(entities.filter((e) => e === "section")).toHaveLength(2);
    expect(entities.filter((e) => e === "task")).toHaveLength(5);
    const hall = pulled.changes.find((c) => c.data?.title === "حجز القاعة")!;
    const sub = pulled.changes.find((c) => c.data?.title === "مقارنة الأسعار")!;
    expect(hall.data).toMatchObject({ priority: 3, tags: ["زواج"], dueDate: "2026-10-20", ownerId: userId });
    expect(sub.data).toMatchObject({ parentId: hall.id, projectId: hall.data!.projectId });
    const project = pulled.changes.find((c) => c.entity === "project")!;
    expect(project.data).toMatchObject({ name: "زواج فهد", ownerId: userId });
  });

  it("is idempotent: the same file again changes nothing, and Zimam edits win", async () => {
    const { token, userId } = await signIn();
    const first = await importFile(token, "todoist-csv", todoistTemplate, "زواج.csv");
    expect(first.counts.created).toBe(8);
    const { cursor } = await pullAll(token);

    const again = await importFile(token, "todoist-csv", todoistTemplate, "زواج.csv");
    expect(again.status).toBe("done");
    expect(again.counts).toMatchObject({ created: 0, updated: 0, unchanged: 8, skipped: 0, failed: 0 });
    expect((await pullAll(token, cursor)).changes).toEqual([]);
    expect(await liveTasks(userId)).toHaveLength(5);

    // The user renames one task in Zimam and deletes another.
    const tasks = await liveTasks(userId);
    const renamed = tasks.find((t) => t.title === "حجز القاعة")!;
    const deleted = tasks.find((t) => t.title === "Confirm the caterer")!;
    const later = Date.now() + 60_000;
    const results = await push(token, [
      { op: "upsert", entity: "task", data: { id: renamed.id, projectId: renamed.project_id, sectionId: renamed.section_id, title: "حجز قاعة الأفراح", updatedAt: later } },
      { op: "delete", entity: "task", id: deleted.id, updatedAt: later },
    ]);
    expect(results.map((r) => r.status)).toEqual(["applied", "applied"]);

    // The source changes a priority: that task is updated, the edited and deleted ones are kept as they are.
    const changed = todoistTemplate.replace("task,مقارنة الأسعار,,1,2", "task,مقارنة الأسعار,,4,2");
    const third = await importFile(token, "todoist-csv", changed, "زواج.csv");
    expect(third.counts).toMatchObject({ created: 0, updated: 1, unchanged: 5, skipped: 2, failed: 0 });
    const after = await liveTasks(userId);
    expect(after.map((t) => t.title)).toEqual(["إرسال الدعوات", "حجز قاعة الأفراح", "شراء البشت، والعقال", "مقارنة الأسعار"]);
    expect(after.find((t) => t.title === "مقارنة الأسعار")!.priority).toBe(3);
  });

  it("imports from the Todoist API with a token that is never stored", async () => {
    const { token, userId } = await signIn();
    const todoistToken = "0123456789abcdef0123456789abcdef01234567";
    const seen: string[] = [];
    todoist = todoistServer(todoistToken, seen);
    const res = await request("POST", "/v1/imports", { token, json: { source: "todoist-api", token: todoistToken } });
    expect(res.status).toBe(202);
    const id = res.body.job.id;
    expect(sent).toEqual([{ jobId: id, cursor: 0, token: todoistToken }]);

    await drain();
    const job = await getJob(token, id);
    // 3 projects (the inbox is Zimam's own), 2 sections (the inbox's is dropped), 4 tasks.
    expect(job).toMatchObject({ status: "done", progress: { processed: 9, total: 9 }, counts: { created: 9, failed: 0 } });
    expect(seen.sort()).toEqual(["/rest/v2/projects", "/rest/v2/sections", "/rest/v2/tasks"]);

    // Nowhere in D1: not in the job, not anywhere a later message would read it from.
    const row = await env.DB.prepare(`SELECT * FROM import_jobs WHERE id = ?`).bind(id).first();
    expect(JSON.stringify(row)).not.toContain(todoistToken);

    const tasks = await liveTasks(userId);
    const morning = tasks.find((t) => t.title === "ورد الصباح")!;
    expect(morning).toMatchObject({ project_id: null, section_id: null, due_date: "2026-10-14", due_time: "05:30", recurrence: "FREQ=DAILY" });
    const folder = await env.DB.prepare(`SELECT * FROM projects WHERE owner_id = ? AND kind = 'folder'`).bind(userId).first();
    expect(folder).toMatchObject({ name: "العمل" });
    const board = await env.DB.prepare(`SELECT * FROM projects WHERE owner_id = ? AND name = 'مشروع الموقع'`).bind(userId).first();
    expect(board).toMatchObject({ parent_id: folder!.id, view: "kanban" });
  });

  it("fails with an Arabic message when Todoist rejects the token", async () => {
    const { token } = await signIn();
    todoist = todoistServer("the-right-token");
    const res = await request("POST", "/v1/imports", { token, json: { source: "todoist-api", token: "a-wrong-token-1234" } });
    await drain();
    const job = await getJob(token, res.body.job.id);
    expect(job.status).toBe("failed");
    expect(job.error).toMatchObject({ code: "token_rejected" });
    expect(job.error!.message).toMatch(/رفض Todoist رمز الوصول/);
  });

  it("retries while the provider is down, then fails after the last attempt", async () => {
    const { token } = await signIn();
    todoist = () => new Response("unavailable", { status: 503, headers: { "Retry-After": "30" } });
    const res = await request("POST", "/v1/imports", { token, json: { source: "todoist-api", token: "a-valid-token-1234" } });
    const message = sent.shift()!;

    const first = await deliver(message, 1);
    // (The test harness does not report delaySeconds; `retryDelay` is checked below.)
    expect(first.retryMessages).toHaveLength(1);
    expect(retryDelay(1, new TransientImportError("down", 30))).toBe(30);
    expect([1, 2, 3].map((n) => retryDelay(n, new Error("d1")))).toEqual([10, 30, 90]);
    expect(retryDelay(1, new TransientImportError("down", 5000))).toBe(900);
    expect(await getJob(token, res.body.job.id)).toMatchObject({ status: "running", error: null });

    // Up again on the next attempt: the import completes from the same message.
    todoist = todoistServer("a-valid-token-1234");
    const second = await deliver(message, 2);
    expect(second.retryMessages).toEqual([]);
    await drain();
    expect(await getJob(token, res.body.job.id)).toMatchObject({ status: "done" });

    // Another import whose provider stays down: the fourth attempt is the last.
    todoist = () => new Response("unavailable", { status: 502 });
    const other = await request("POST", "/v1/imports", { token, json: { source: "todoist-api", token: "a-valid-token-1234" } });
    const last = await deliver(sent.shift()!, 4);
    expect(last.retryMessages).toEqual([]);
    expect(last.explicitAcks).toHaveLength(1);
    const failed = await getJob(token, other.body.job.id);
    expect(failed).toMatchObject({ status: "failed", error: { code: "source_unavailable" } });
    expect(failed.error!.message).toMatch(/تعذّر الوصول إلى المصدر/);
  });

  it("writes large imports in chunks, with progress, and survives a retried chunk", async () => {
    const { token, userId } = await signIn();
    const rows = Array.from({ length: 120 }, (_, i) => `مهمة رقم ${i + 1},2026-11-${String((i % 28) + 1).padStart(2, "0")}`);
    const csv = `العنوان,التاريخ\n${rows.join("\n")}\n`;
    const res = await upload(token, "csv", csv, "مهام.csv");
    const id = res.body.job.id;

    await deliver(sent.shift()!);
    let job = await getJob(token, id);
    expect(job).toMatchObject({ status: "running", progress: { processed: CHUNK_SIZE, total: 120 } });
    expect(sent).toEqual([{ jobId: id, cursor: CHUNK_SIZE }]);

    // A duplicate of the first message is dropped.
    const duplicate = await deliver({ jobId: id, cursor: 0 });
    expect(duplicate.explicitAcks).toHaveLength(1);

    // The second chunk is written, but sending the next message fails: the chunk is retried.
    failEnqueue = true;
    const next = sent.shift()!;
    const failed = await deliver(next);
    expect(failed.retryMessages).toHaveLength(1);
    expect((await getJob(token, id)).progress.processed).toBe(CHUNK_SIZE);
    failEnqueue = false;
    await deliver(next, 2);
    await drain();

    job = await getJob(token, id);
    expect(job).toMatchObject({ status: "done", progress: { processed: 120, total: 120 } });
    // The retried chunk found its records already written: no copies.
    expect(job.counts).toMatchObject({ created: 70, unchanged: 50, failed: 0 });
    expect(await liveTasks(userId)).toHaveLength(120);
  });

  it("imports TickTick reminders and Google Tasks completion state", async () => {
    const { token, userId } = await signIn();
    const tick = await importFile(token, "ticktick-csv", tickTickBackup, "TickTick-backup.csv");
    expect(tick).toMatchObject({ status: "done", counts: { failed: 0 } });
    expect(tick.counts.byEntity.reminder).toMatchObject({ created: 3 });
    const pulled = await pullAll(token);
    const reminders = pulled.changes.filter((c) => c.entity === "reminder");
    expect(reminders.map((r) => r.data!.at).sort()).toEqual(["2026-10-20T09:00:00+03:00", "2026-10-21T09:15:00+03:00", "2026-10-21T09:30:00+03:00"]);

    const google = await importFile(token, "google-tasks", googleTasksJson, "Tasks.json");
    expect(google).toMatchObject({ status: "done", counts: { created: 6, failed: 0 } });
    const paid = (await liveTasks(userId)).find((t) => t.title === "Pay electricity bill")!;
    expect(paid).toMatchObject({ status: "done", completed_at: Date.parse("2026-10-05T14:20:00Z"), due_date: "2026-10-05" });
  });

  it("fails a file that is not what it claims to be, with an Arabic message", async () => {
    const { token } = await signIn();
    const job = await importFile(token, "ticktick-csv", "name,phone\nفهد,0500000000\n", "contacts.csv");
    expect(job.status).toBe("failed");
    expect(job.error).toMatchObject({ code: "invalid_file" });
    expect(job.error!.message).toMatch(/TickTick/);
    expect(await r2Keys(job.id)).toBe(0);

    const broken = await importFile(token, "google-tasks", "{ this is not json", "Tasks.json");
    expect(broken.error).toMatchObject({ code: "invalid_file" });

    const empty = await importFile(token, "csv", "العنوان,التاريخ\n", "فارغ.csv");
    expect(empty.error).toMatchObject({ code: "nothing_to_import" });
    expect(empty.error!.message).toMatch(/لم نجد/);
  });

  it("refuses files over the size limit and wrong inputs", async () => {
    const { token } = await signIn();
    const big = new Uint8Array(MAX_UPLOAD_BYTES + 1).fill(0x61);
    const tooBig = await upload(token, "csv", big, "big.csv");
    expect(tooBig.status).toBe(413);
    expect(tooBig.body.error.code).toBe("file_too_large");
    expect(sent).toEqual([]);

    expect((await upload(token, "trello", "x", "x.csv")).body.error.code).toBe("invalid_source");
    expect((await upload(token, "todoist-api", "x", "x.csv")).body.error.code).toBe("invalid_source");
    expect((await upload(token, "google-tasks", "{}", "Tasks.csv")).body.error.code).toBe("invalid_file_type");
    expect((await upload(token, "csv", "", "empty.csv")).body.error.code).toBe("empty_file");
    expect((await request("POST", "/v1/imports", { token, json: { source: "csv", token: "abcdefgh" } })).status).toBe(400);
    expect((await request("POST", "/v1/imports", { token, json: { source: "todoist-api" } })).status).toBe(400);
    expect((await request("POST", "/v1/imports", { json: { source: "todoist-api", token: "abcdefgh" } })).status).toBe(401);
  });

  it("runs one import at a time per user", async () => {
    const { token } = await signIn();
    expect((await upload(token, "csv", "title\nأ\n", "a.csv")).status).toBe(202);
    const second = await upload(token, "csv", "title\nب\n", "b.csv");
    expect(second.status).toBe(409);
    expect(second.body.error.code).toBe("import_in_progress");
    await drain();
    expect((await upload(token, "csv", "title\nب\n", "b.csv")).status).toBe(202);
  });

  it("fails the job when the queue cannot take it", async () => {
    const { token } = await signIn();
    failEnqueue = true;
    const res = await upload(token, "csv", "title\nأ\n", "a.csv");
    expect(res.status).toBe(503);
    const { jobs } = (await request("GET", "/v1/imports", { token })).body as { jobs: Job[] };
    expect(jobs[0]).toMatchObject({ status: "failed", error: { code: "unavailable" } });
    expect(await r2Keys(jobs[0]!.id)).toBe(0);
  });

  it("shows a user only their own imports", async () => {
    const a = await signIn();
    const b = await signIn();
    const res = await upload(a.token, "csv", "title\nأ\n", "a.csv");
    const id = res.body.job.id;
    expect((await request("GET", `/v1/imports/${id}`, { token: a.token })).status).toBe(200);
    expect((await request("GET", `/v1/imports/${id}`, { token: b.token })).status).toBe(404);
    expect((await request("GET", "/v1/imports/not-a-uuid", { token: b.token })).status).toBe(404);
    expect((await request("GET", "/v1/imports", { token: b.token })).body.jobs).toEqual([]);
    expect((await request("GET", "/v1/imports", { token: a.token })).body.jobs.map((j: Job) => j.id)).toEqual([id]);
  });

  it("fails a job from the dead-letter queue through the Worker's queue handler", async () => {
    const { token } = await signIn();
    const res = await upload(token, "csv", "title\nأ\n", "a.csv");
    const batch = createMessageBatch(IMPORT_DEAD_LETTER_QUEUE, [{ id: "dlq-1", timestamp: Date.now(), attempts: 1, body: sent.shift()! }]);
    const ctx = createExecutionContext();
    await worker.queue(batch, env, ctx);
    expect((await getQueueResult(batch, ctx)).explicitAcks).toEqual(["dlq-1"]);
    const job = await getJob(token, res.body.job.id);
    expect(job).toMatchObject({ status: "failed", error: { code: "internal" } });
    expect(await r2Keys(job.id)).toBe(0);
  });

  it("deletes a user's imports with their account, and the queue drops what is left", async () => {
    const { token } = await signIn();
    const res = await upload(token, "csv", "title\nأ\n", "a.csv");
    const id = res.body.job.id;
    expect((await call("DELETE", "/v1/me", { token })).status).toBe(204);
    expect(await env.DB.prepare(`SELECT 1 FROM import_jobs WHERE id = ?`).bind(id).first()).toBeNull();
    const result = await deliver(sent.shift()!);
    expect(result.explicitAcks).toHaveLength(1);
    expect(await r2Keys(id)).toBe(0);
  });
});
