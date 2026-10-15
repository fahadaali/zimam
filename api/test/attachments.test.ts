import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import {
  ATTACHMENT_TYPES,
  attachmentKey,
  classify,
  cleanFileName,
  contentDisposition,
  MAX_ATTACHMENT_BYTES,
  MAX_ATTACHMENTS_PER_TASK,
  purgeAttachments,
  storageLimit,
} from "../src/attachments";
import type { Env } from "../src/env";
import worker from "../src/index";
import { addMember, app, call, pullAll, signIn, uuid } from "./helpers";

type User = Awaited<ReturnType<typeof signIn>>;

interface Attachment {
  id: string;
  taskId: string;
  projectId: string | null;
  uploaderId: string;
  uploaderName: string | null;
  fileName: string;
  contentType: string;
  size: number;
  createdAt: number;
  updatedAt: number;
}

// MARK: Helpers

async function createProject(owner: User, name = "مشروع الأسرة") {
  const res = await call("POST", "/v1/projects", { token: owner.token, body: { name } });
  return res.body.id as string;
}

async function createTask(user: User, body: Record<string, unknown> = {}) {
  const res = await call("POST", "/v1/tasks", { token: user.token, body: { title: "تجهيز الأوراق", ...body } });
  expect(res.status).toBe(201);
  return res.body.id as string;
}

function file(name: string, size = 1200, type = "") {
  return new File([new Uint8Array(size).fill(65)], name, { type });
}

async function send(method: string, path: string, o: { token?: string; form?: FormData; env?: Partial<Env> } = {}) {
  const headers = new Headers();
  if (o.token) headers.set("Authorization", `Bearer ${o.token}`);
  return app.fetch(new Request(`https://api.zimam.test${path}`, { method, headers, body: o.form }), o.env ? { ...env, ...o.env } : env);
}

async function upload(user: User, taskId: string, f: File, extra?: Partial<Env>) {
  const form = new FormData();
  form.set("file", f);
  const response = await send("POST", `/v1/tasks/${taskId}/attachments`, { token: user.token, form, env: extra });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

async function list(user: User, taskId: string) {
  return call("GET", `/v1/tasks/${taskId}/attachments`, { token: user.token });
}

const remove = (user: User, id: string) => call("DELETE", `/v1/attachments/${id}`, { token: user.token });

/** Pulls with attachment metadata, as a client that asks for it. */
async function pullWithAttachments(token: string, cursor = 0) {
  const res = await call("GET", `/v1/sync?cursor=${cursor}&include=attachment`, { token });
  return res.body as { changes: { entity: string; id: string; op: string; data?: Record<string, unknown> }[]; cursor: number };
}

const attachmentChanges = (changes: { entity: string; id: string; op: string; data?: Record<string, unknown> }[], id: string) =>
  changes.filter((c) => c.entity === "attachment" && c.id === id);

async function row(id: string) {
  return env.DB.prepare(`SELECT * FROM attachments WHERE id = ?`).bind(id).first<Record<string, unknown>>();
}

// MARK: Rules

describe("Attachment rules", () => {
  it("allows images, PDF, text and Office documents by extension, never what a browser runs", () => {
    expect(classify("عقد الإيجار.PDF", "application/octet-stream")).toEqual({ fileName: "عقد الإيجار.PDF", contentType: "application/pdf" });
    expect(classify("photo.HEIC", "")!.contentType).toBe("image/heic");
    expect(classify("ميزانية.xlsx", "")!.contentType).toBe(ATTACHMENT_TYPES[".xlsx"]);
    expect(classify("notes.txt", "text/html")!.contentType).toBe("text/plain; charset=utf-8");
    for (const name of ["page.html", "logo.svg", "run.exe", "script.js", "archive.zip"]) expect(classify(name, "image/png")).toBeNull();
    // A name without an extension takes an allowed client type's.
    expect(classify("لصق", "image/png")).toEqual({ fileName: "لصق.png", contentType: "image/png" });
    expect(classify("", "image/jpeg")!.fileName).toBe("ملف.jpg");
    expect(classify("blob", "text/html")).toBeNull();
    expect(classify(".pdf", "")!.fileName).toBe("ملف.pdf");
  });

  it("cleans names: path parts, control and bidi characters, and length", () => {
    expect(cleanFileName("C:\\Users\\me\\تقرير.docx")).toBe("تقرير.docx");
    expect(cleanFileName("../../etc/passwd.txt")).toBe("passwd.txt");
    expect(cleanFileName("فاتورة\u202Efdp.exe")).toBe("فاتورةfdp.exe");
    expect(cleanFileName("a\nb\tc.txt")).toBe("a b c.txt");
    const long = cleanFileName(`${"م".repeat(300)}.pdf`);
    expect(long).toHaveLength(200);
    expect(long.endsWith(".pdf")).toBe(true);
  });

  it("names the download in ASCII and UTF-8", () => {
    expect(contentDisposition('عقد "نهائي".pdf')).toBe(
      `attachment; filename="___ _______.pdf"; filename*=UTF-8''${encodeURIComponent('عقد "نهائي".pdf')}`,
    );
    expect(contentDisposition("it's (1).txt")).toBe(`attachment; filename="it's (1).txt"; filename*=UTF-8''it%27s%20%281%29.txt`);
  });

  it("gives each plan its storage, from the vars or the defaults", () => {
    expect(storageLimit(env, "free")).toBe(1024 * 1024 * 1024);
    expect(storageLimit(env, "pro")).toBe(10 * 1024 * 1024 * 1024);
    expect(storageLimit({ ATTACHMENT_QUOTA_MB_FREE: "5" }, "free")).toBe(5 * 1024 * 1024);
    expect(storageLimit({}, "pro")).toBe(10 * 1024 * 1024 * 1024);
    expect(storageLimit({ ATTACHMENT_QUOTA_MB_PRO: "lots" }, "pro")).toBe(10 * 1024 * 1024 * 1024);
  });
});

// MARK: Routes

describe("Uploading, listing and downloading", () => {
  it("keeps the file in R2 and serves it to whoever can see the task", async () => {
    const owner = await signIn(undefined, "سارة");
    const viewer = await signIn();
    const outsider = await signIn();
    const projectId = await createProject(owner);
    await addMember(projectId, viewer.userId, "viewer");
    const taskId = await createTask(owner, { projectId });

    const created = await upload(owner, taskId, file("عقد الإيجار.pdf", 2048, "application/pdf"));
    expect(created.status).toBe(201);
    const attachment = created.body as Attachment;
    expect(attachment).toEqual({
      id: expect.any(String),
      taskId,
      projectId,
      uploaderId: owner.userId,
      uploaderName: "سارة",
      fileName: "عقد الإيجار.pdf",
      contentType: "application/pdf",
      size: 2048,
      createdAt: expect.any(Number),
      updatedAt: expect.any(Number),
      canDelete: true,
    });
    const object = await env.ATTACHMENTS.get(attachmentKey(attachment.id));
    expect(object!.size).toBe(2048);
    expect(object!.customMetadata).toEqual({ taskId, userId: owner.userId });

    const listed = await list(viewer, taskId.toUpperCase());
    expect(listed.status).toBe(200);
    expect(listed.body).toEqual({ attachments: [{ ...attachment, canDelete: false }], maxFileBytes: MAX_ATTACHMENT_BYTES, canAdd: false });
    expect((await list(owner, taskId)).body).toMatchObject({ canAdd: true, attachments: [{ canDelete: true }] });

    const download = await send("GET", `/v1/attachments/${attachment.id.toUpperCase()}`, { token: viewer.token });
    expect(download.status).toBe(200);
    expect(download.headers.get("Content-Type")).toBe("application/pdf");
    expect(download.headers.get("Content-Length")).toBe("2048");
    expect(download.headers.get("Content-Disposition")).toBe(contentDisposition("عقد الإيجار.pdf"));
    expect(download.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(download.headers.get("Content-Security-Policy")).toContain("sandbox");
    expect(download.headers.get("Cache-Control")).toBe("private, no-store");
    expect((await download.arrayBuffer()).byteLength).toBe(2048);

    // Outside the project the task, its files and the downloads do not exist.
    expect((await list(outsider, taskId)).status).toBe(404);
    expect((await send("GET", `/v1/attachments/${attachment.id}`, { token: outsider.token })).status).toBe(404);
    expect((await remove(outsider, attachment.id)).status).toBe(404);
    expect((await upload(outsider, taskId, file("x.txt"))).status).toBe(404);
    expect((await send("GET", `/v1/attachments/${attachment.id}`)).status).toBe(401);
    expect((await send("GET", `/v1/attachments/not-a-uuid`, { token: owner.token })).status).toBe(404);
  });

  it("lets editors attach, and refuses viewers", async () => {
    const owner = await signIn();
    const editor = await signIn();
    const viewer = await signIn();
    const projectId = await createProject(owner);
    await addMember(projectId, editor.userId, "editor");
    await addMember(projectId, viewer.userId, "viewer");
    const taskId = await createTask(owner, { projectId });

    expect((await upload(editor, taskId, file("صورة.jpg", 500, "image/jpeg"))).status).toBe(201);
    const refused = await upload(viewer, taskId, file("صورة.jpg"));
    expect([refused.status, refused.body.error.code]).toEqual([403, "forbidden"]);
    expect((await list(owner, taskId)).body.attachments).toHaveLength(1);
  });

  it("enforces size, type and count limits", async () => {
    const user = await signIn();
    const taskId = await createTask(user);

    const big = await upload(user, taskId, file("كبير.pdf", MAX_ATTACHMENT_BYTES + 1));
    expect([big.status, big.body.error.code]).toEqual([413, "file_too_large"]);
    const empty = await upload(user, taskId, file("فارغ.txt", 0));
    expect([empty.status, empty.body.error.code]).toEqual([400, "empty_file"]);
    for (const name of ["page.html", "logo.svg", "setup.exe"]) {
      const res = await upload(user, taskId, file(name, 10, "image/png"));
      expect([res.status, res.body.error.code]).toEqual([400, "invalid_file_type"]);
    }
    const json = await send("POST", `/v1/tasks/${taskId}/attachments`, { token: user.token });
    expect(json.status).toBe(400);
    const noFile = new FormData();
    noFile.set("name", "x");
    expect((await send("POST", `/v1/tasks/${taskId}/attachments`, { token: user.token, form: noFile })).status).toBe(400);

    // The largest file is fine.
    expect((await upload(user, taskId, file("حد.pdf", MAX_ATTACHMENT_BYTES))).status).toBe(201);

    // A task holds a bounded number of files.
    const other = await createTask(user);
    const now = Date.now();
    await env.DB.batch(
      Array.from({ length: MAX_ATTACHMENTS_PER_TASK }, () =>
        env.DB.prepare(
          `INSERT INTO attachments (id, task_id, project_id, user_id, file_name, content_type, size, r2_key, created_at, updated_at)
           VALUES (?, ?, NULL, ?, 'a.txt', 'text/plain', 1, NULL, ?, ?)`,
        ).bind(uuid(), other, user.userId, now, now),
      ),
    );
    const tooMany = await upload(user, other, file("واحد.txt"));
    expect([tooMany.status, tooMany.body.error.code]).toEqual([409, "too_many_attachments"]);
  });

  it("keeps each uploader within their plan's storage", async () => {
    const user = await signIn();
    const taskId = await createTask(user);
    const oneMb = { ATTACHMENT_QUOTA_MB_PRO: "1" };
    expect((await upload(user, taskId, file("أ.pdf", 600 * 1024), oneMb)).status).toBe(201);
    const full = await upload(user, taskId, file("ب.pdf", 600 * 1024), oneMb);
    expect(full.status).toBe(413);
    expect(full.body.error).toMatchObject({ code: "storage_quota_exceeded", limit: 1024 * 1024, used: 600 * 1024, plan: "pro" });

    // Deleting frees the space.
    const [first] = (await list(user, taskId)).body.attachments as Attachment[];
    expect((await remove(user, first!.id)).status).toBe(204);
    expect((await upload(user, taskId, file("ب.pdf", 600 * 1024), oneMb)).status).toBe(201);

    // When plans are enforced, a free user has the free storage.
    const free = await upload(user, taskId, file("ج.pdf", 10), { SUBSCRIPTIONS_ENFORCED: "true", ATTACHMENT_QUOTA_MB_FREE: "0" });
    expect(free.body.error).toMatchObject({ code: "storage_quota_exceeded", limit: 0, plan: "free" });
  });
});

describe("Deleting an attachment", () => {
  it("is for the uploader or the project owner, and removes the file from R2", async () => {
    const owner = await signIn();
    const editor = await signIn();
    const other = await signIn();
    const projectId = await createProject(owner);
    await addMember(projectId, editor.userId, "editor");
    await addMember(projectId, other.userId, "editor");
    const taskId = await createTask(owner, { projectId });

    const mine = (await upload(editor, taskId, file("أ.txt"))).body as Attachment;
    const theirs = (await upload(editor, taskId, file("ب.txt"))).body as Attachment;
    const flags = async (user: User) => (await list(user, taskId)).body.attachments.map((a: { canDelete: boolean }) => a.canDelete);
    expect(await flags(editor)).toEqual([true, true]);
    expect(await flags(owner)).toEqual([true, true]);
    expect(await flags(other)).toEqual([false, false]);

    const refused = await remove(other, mine.id);
    expect([refused.status, refused.body.error.code]).toEqual([403, "forbidden"]);
    expect((await remove(editor, mine.id)).status).toBe(204);
    expect((await remove(owner, theirs.id)).status).toBe(204);

    for (const id of [mine.id, theirs.id]) {
      expect(await env.ATTACHMENTS.get(attachmentKey(id))).toBeNull();
      expect(await row(id)).toMatchObject({ deleted_at: expect.any(Number), r2_key: null });
      expect((await send("GET", `/v1/attachments/${id}`, { token: owner.token })).status).toBe(404);
      expect((await remove(owner, id)).status).toBe(404);
    }
    expect((await list(owner, taskId)).body.attachments).toEqual([]);
  });

  it("is for the owner on an inbox task", async () => {
    const user = await signIn();
    const taskId = await createTask(user);
    const a = (await upload(user, taskId, file("صورة.png", 10, "image/png"))).body as Attachment;
    expect(a.projectId).toBeNull();
    expect((await remove(user, a.id)).status).toBe(204);
  });
});

// MARK: Sync

describe("Attachment change rows", () => {
  it("reach clients that ask for them, with the task's audience, and never older apps", async () => {
    const owner = await signIn();
    const member = await signIn();
    const outsider = await signIn();
    const projectId = await createProject(owner);
    await addMember(projectId, member.userId, "editor");
    const taskId = await createTask(owner, { projectId });
    const before = (await pullAll(member.token)).cursor;

    const a = (await upload(owner, taskId, file("خطة.docx", 300))).body as Attachment;

    const pulled = await pullWithAttachments(member.token, before);
    expect(attachmentChanges(pulled.changes, a.id)).toEqual([
      {
        entity: "attachment",
        id: a.id,
        op: "upsert",
        data: { id: a.id, taskId, projectId, uploaderId: owner.userId, fileName: "خطة.docx", contentType: ATTACHMENT_TYPES[".docx"], size: 300, createdAt: a.createdAt, updatedAt: a.updatedAt },
      },
    ]);
    // An app that does not ask never sees the entity, but its cursor moves past the row.
    const old = await pullAll(member.token, before);
    expect(old.changes.filter((c) => c.entity === "attachment")).toEqual([]);
    expect(old.cursor).toBe(pulled.cursor);
    expect(attachmentChanges((await pullWithAttachments(outsider.token)).changes, a.id)).toEqual([]);
    // Unknown names in include are ignored.
    expect((await call("GET", `/v1/sync?cursor=${before}&include=attachment,users`, { token: member.token })).status).toBe(200);

    expect((await remove(owner, a.id)).status).toBe(204);
    expect(attachmentChanges((await pullWithAttachments(member.token, pulled.cursor)).changes, a.id)).toEqual([
      { entity: "attachment", id: a.id, op: "delete" },
    ]);
  });

  it("follow a task moved to another project, and reach a member who joins later", async () => {
    const owner = await signIn();
    const oldMember = await signIn();
    const newMember = await signIn();
    const from = await createProject(owner, "قديم");
    const to = await createProject(owner, "جديد");
    await addMember(from, oldMember.userId, "editor");
    await addMember(to, newMember.userId, "editor");
    const taskId = await createTask(owner, { projectId: from });
    const subtaskId = await createTask(owner, { projectId: from, parentId: taskId });
    const a = (await upload(owner, taskId, file("أ.pdf"))).body as Attachment;
    const b = (await upload(owner, subtaskId, file("ب.pdf"))).body as Attachment;
    const oldCursor = (await pullWithAttachments(oldMember.token)).cursor;
    const newCursor = (await pullWithAttachments(newMember.token)).cursor;

    expect((await call("PATCH", `/v1/tasks/${taskId}`, { token: owner.token, body: { projectId: to } })).status).toBe(200);
    expect((await row(a.id))!.project_id).toBe(to);
    expect((await row(b.id))!.project_id).toBe(to);

    const gained = await pullWithAttachments(newMember.token, newCursor);
    expect(attachmentChanges(gained.changes, a.id)).toEqual([expect.objectContaining({ op: "upsert", data: expect.objectContaining({ projectId: to }) })]);
    expect(attachmentChanges(gained.changes, b.id)).toEqual([expect.objectContaining({ op: "upsert" })]);
    const lost = await pullWithAttachments(oldMember.token, oldCursor);
    expect(attachmentChanges(lost.changes, a.id)).toEqual([{ entity: "attachment", id: a.id, op: "delete" }]);
    expect(attachmentChanges(lost.changes, b.id)).toEqual([{ entity: "attachment", id: b.id, op: "delete" }]);
    expect((await list(newMember, taskId)).body.attachments).toHaveLength(1);
    expect((await list(oldMember, taskId)).status).toBe(404);

    // Someone who joins after the upload gets it with the project.
    const late = await signIn();
    const invite = await call("POST", `/v1/projects/${to}/invites`, { token: owner.token, body: { role: "viewer" } });
    const lateCursor = (await pullWithAttachments(late.token)).cursor;
    expect((await call("POST", `/v1/invites/${invite.body.code}/accept`, { token: late.token })).status).toBe(200);
    const joined = await pullWithAttachments(late.token, lateCursor);
    expect(attachmentChanges(joined.changes, a.id)).toEqual([expect.objectContaining({ op: "upsert" })]);
  });
});

// MARK: Cascades

describe("Deleting what an attachment is on", () => {
  it("deletes the attachments of a task and its subtasks, and the cron removes their files", async () => {
    const user = await signIn();
    const taskId = await createTask(user);
    const subtaskId = await createTask(user, { parentId: taskId });
    const a = (await upload(user, taskId, file("أ.txt"))).body as Attachment;
    const b = (await upload(user, subtaskId, file("ب.txt"))).body as Attachment;
    const cursor = (await pullWithAttachments(user.token)).cursor;

    expect((await call("DELETE", `/v1/tasks/${taskId}`, { token: user.token })).status).toBe(204);
    for (const id of [a.id, b.id]) expect(await row(id)).toMatchObject({ deleted_at: expect.any(Number), r2_key: attachmentKey(id) });
    const pulled = await pullWithAttachments(user.token, cursor);
    expect(attachmentChanges(pulled.changes, a.id)).toEqual([{ entity: "attachment", id: a.id, op: "delete" }]);
    expect(attachmentChanges(pulled.changes, b.id)).toEqual([{ entity: "attachment", id: b.id, op: "delete" }]);

    // The cron (every 5 minutes) removes the files.
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({ scheduledTime: Date.now(), cron: "*/5 * * * *" }), env, ctx);
    await waitOnExecutionContext(ctx);
    for (const id of [a.id, b.id]) {
      expect(await env.ATTACHMENTS.get(attachmentKey(id))).toBeNull();
      expect((await row(id))!.r2_key).toBeNull();
    }
    expect(await purgeAttachments(env.DB, env.ATTACHMENTS)).toBe(0);
  });

  it("deletes the attachments of a deleted project", async () => {
    const owner = await signIn();
    const member = await signIn();
    const projectId = await createProject(owner);
    await addMember(projectId, member.userId, "editor");
    const taskId = await createTask(owner, { projectId });
    const a = (await upload(member, taskId, file("أ.png", 10, "image/png"))).body as Attachment;
    const cursor = (await pullWithAttachments(member.token)).cursor;

    expect((await call("DELETE", `/v1/projects/${projectId}`, { token: owner.token })).status).toBe(204);
    expect((await row(a.id))!.deleted_at).toEqual(expect.any(Number));
    expect(attachmentChanges((await pullWithAttachments(member.token, cursor)).changes, a.id)).toEqual([
      { entity: "attachment", id: a.id, op: "delete" },
    ]);
    await purgeAttachments(env.DB, env.ATTACHMENTS);
    expect(await env.ATTACHMENTS.get(attachmentKey(a.id))).toBeNull();
  });

  it("does not attach to a task deleted in the meantime", async () => {
    const user = await signIn();
    const taskId = await createTask(user);
    await call("DELETE", `/v1/tasks/${taskId}`, { token: user.token });
    expect((await upload(user, taskId, file("أ.txt"))).status).toBe(404);
  });

  it("deletes a deleted account's uploads everywhere, with their files and names", async () => {
    const owner = await signIn();
    const leaver = await signIn();
    const projectId = await createProject(owner);
    await addMember(projectId, leaver.userId, "editor");
    const shared = await createTask(owner, { projectId });
    const inbox = await createTask(leaver);
    const inShared = (await upload(leaver, shared, file("سري.pdf"))).body as Attachment;
    const ownersFile = (await upload(owner, shared, file("للمالك.pdf"))).body as Attachment;
    const inInbox = (await upload(leaver, inbox, file("خاص.txt"))).body as Attachment;
    const cursor = (await pullWithAttachments(owner.token)).cursor;

    expect((await call("DELETE", "/v1/me", { token: leaver.token })).status).toBe(204);

    for (const id of [inShared.id, inInbox.id]) {
      expect(await row(id)).toMatchObject({ deleted_at: expect.any(Number), file_name: "", r2_key: null });
      expect(await env.ATTACHMENTS.get(attachmentKey(id))).toBeNull();
    }
    // The task they worked on stays with the project, and so does what others attached to it.
    expect((await list(owner, shared)).body.attachments.map((a: Attachment) => a.id)).toEqual([ownersFile.id]);
    expect(await env.ATTACHMENTS.get(attachmentKey(ownersFile.id))).not.toBeNull();
    expect(attachmentChanges((await pullWithAttachments(owner.token, cursor)).changes, inShared.id)).toEqual([
      { entity: "attachment", id: inShared.id, op: "delete" },
    ]);
  });
});
