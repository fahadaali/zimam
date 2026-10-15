import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { sha256Hex } from "../src/auth/crypto";
import { addMember, call, pullAll, push, signIn, uuid } from "./helpers";

type User = Awaited<ReturnType<typeof signIn>>;

async function createProject(owner: User, name = "مشروع مشترك") {
  const res = await call("POST", "/v1/projects", { token: owner.token, body: { name } });
  return res.body.id as string;
}

const invite = (user: User, projectId: string, role: string = "editor") =>
  call("POST", `/v1/projects/${projectId}/invites`, { token: user.token, body: { role } });

const accept = (user: User, code: string) => call("POST", `/v1/invites/${code}/accept`, { token: user.token });

async function join(owner: User, member: User, projectId: string, role: "editor" | "viewer" = "editor") {
  const { body } = await invite(owner, projectId, role);
  const res = await accept(member, body.code);
  if (res.status !== 200) throw new Error(`accept failed: ${JSON.stringify(res.body)}`);
}

const addTask = (user: User, projectId: string, extra = {}) =>
  call("POST", "/v1/tasks", { token: user.token, body: { title: "مهمة", projectId, ...extra } });

const comment = (user: User, taskId: string, body: unknown = "تم") =>
  call("POST", `/v1/tasks/${taskId}/comments`, { token: user.token, body: { body } });

/** Moves a user's sync cursor past everything that exists so far. */
async function cursorNow(user: User) {
  await push(user.token, [{ op: "upsert", entity: "task", data: { id: uuid(), title: "خاصة", updatedAt: 1 } }]);
  return (await pullAll(user.token)).cursor;
}

describe("Invites", () => {
  it("lets only the owner create and list them", async () => {
    const owner = await signIn();
    const editor = await signIn();
    const outsider = await signIn();
    const projectId = await createProject(owner);
    await addMember(projectId, editor.userId, "editor");

    const created = await invite(owner, projectId, "viewer");
    expect(created.status).toBe(201);
    expect(created.body.url).toBe(`https://zimam-web.fahad2ao.workers.dev/join/#${created.body.code}`);
    expect(created.body.code).toMatch(/^[A-Za-z0-9_-]{40,}$/);
    expect(created.body.expiresAt - Date.now()).toBeGreaterThan(6.9 * 24 * 3600 * 1000);

    // Only the hash is stored.
    const stored = await env.DB.prepare(`SELECT code_hash FROM invites WHERE project_id = ?`).bind(projectId).first<{ code_hash: string }>();
    expect(stored!.code_hash).toBe(await sha256Hex(created.body.code));

    expect((await invite(editor, projectId)).status).toBe(403);
    expect((await invite(outsider, projectId)).status).toBe(404);
    expect((await invite(owner, projectId, "owner")).status).toBe(400);

    const list = await call("GET", `/v1/projects/${projectId}/invites`, { token: owner.token });
    expect(list.body.invites).toEqual([
      { id: created.body.id, role: "viewer", createdBy: owner.userId, createdAt: expect.any(Number), expiresAt: created.body.expiresAt },
    ]);
    expect(JSON.stringify(list.body)).not.toContain(created.body.code);
    expect((await call("GET", `/v1/projects/${projectId}/invites`, { token: editor.token })).status).toBe(403);
  });

  it("cannot share a folder", async () => {
    const owner = await signIn();
    const folder = await call("POST", "/v1/projects", { token: owner.token, body: { name: "مجلد", kind: "folder" } });
    expect((await invite(owner, folder.body.id)).status).toBe(400);
  });

  it("previews an invite before joining", async () => {
    const owner = await signIn(undefined, "فهد");
    const guest = await signIn();
    const projectId = await createProject(owner, "رحلة العمرة");
    const { body } = await invite(owner, projectId, "viewer");

    const preview = await call("GET", `/v1/invites/${body.code}`, { token: guest.token });
    expect(preview.status).toBe(200);
    expect(preview.body).toEqual({ projectName: "رحلة العمرة", role: "viewer", invitedBy: "فهد", expiresAt: body.expiresAt });
    expect((await call("GET", `/v1/invites/${body.code}`)).status).toBe(401);
    expect((await call("GET", `/v1/invites/not-a-real-code`, { token: guest.token })).status).toBe(404);
  });

  it("delivers the whole project to a new member's next pull", async () => {
    const owner = await signIn();
    const member = await signIn(undefined, "سارة");
    const projectId = uuid();
    const sectionId = uuid();
    const taskId = uuid();
    const subtaskId = uuid();
    const commentId = uuid();
    const deletedId = uuid();
    const results = await push(owner.token, [
      { op: "upsert", entity: "project", data: { id: projectId, name: "البيت", view: "kanban", updatedAt: 1000 } },
      { op: "upsert", entity: "section", data: { id: sectionId, projectId, name: "قيد العمل", updatedAt: 1000 } },
      { op: "upsert", entity: "task", data: { id: taskId, projectId, sectionId, title: "دهان", updatedAt: 1000 } },
      { op: "upsert", entity: "task", data: { id: subtaskId, projectId, parentId: taskId, title: "شراء", updatedAt: 1000 } },
      { op: "upsert", entity: "task", data: { id: deletedId, projectId, title: "محذوفة", updatedAt: 1000 } },
      { op: "delete", entity: "task", id: deletedId, updatedAt: 2000 },
      { op: "upsert", entity: "comment", data: { id: commentId, taskId, body: "اللون أبيض", updatedAt: 1000 } },
    ]);
    expect(results.every((r) => r.status === "applied")).toBe(true);

    const cursor = await cursorNow(member);
    await join(owner, member, projectId, "viewer");

    const pulled = await pullAll(member.token, cursor);
    expect(pulled.changes.every((c) => c.op === "upsert")).toBe(true);
    // The project arrives before what it contains.
    expect(pulled.changes.map((c) => c.entity)).toEqual(["project", "section", "task", "task", "comment"]);
    expect(pulled.changes.map((c) => c.id).sort()).toEqual([projectId, sectionId, taskId, subtaskId, commentId].sort());
    expect(pulled.changes[0]!.data).toMatchObject({ name: "البيت", view: "kanban" });

    const members = await call("GET", `/v1/projects/${projectId}/members`, { token: member.token });
    expect(members.body.members).toEqual([
      { userId: owner.userId, name: null, role: "owner", addedAt: expect.any(Number) },
      { userId: member.userId, name: "سارة", role: "viewer", addedAt: expect.any(Number) },
    ]);
    expect((await call("GET", `/v1/projects/${projectId}`, { token: member.token })).body.role).toBe("viewer");
  });

  it("can be used only once", async () => {
    const owner = await signIn();
    const first = await signIn();
    const second = await signIn();
    const projectId = await createProject(owner);
    const { body } = await invite(owner, projectId);

    const accepted = await accept(first, body.code);
    expect(accepted.status).toBe(200);
    expect(accepted.body).toEqual({ projectId, role: "editor" });
    const again = await accept(second, body.code);
    expect(again.status).toBe(410);
    expect(again.body.error.code).toBe("invite_used");
    expect((await call("GET", `/v1/invites/${body.code}`, { token: second.token })).status).toBe(410);
    expect((await call("GET", `/v1/projects/${projectId}`, { token: second.token })).status).toBe(404);
    expect((await call("GET", `/v1/projects/${projectId}/invites`, { token: owner.token })).body.invites).toEqual([]);
  });

  it("expires", async () => {
    const owner = await signIn();
    const guest = await signIn();
    const projectId = await createProject(owner);
    const { body } = await invite(owner, projectId);
    await env.DB.prepare(`UPDATE invites SET expires_at = ? WHERE code_hash = ?`)
      .bind(Date.now() - 1, await sha256Hex(body.code))
      .run();

    const preview = await call("GET", `/v1/invites/${body.code}`, { token: guest.token });
    expect(preview.status).toBe(410);
    expect(preview.body.error.code).toBe("invite_expired");
    expect((await accept(guest, body.code)).status).toBe(410);
    expect((await call("GET", `/v1/projects/${projectId}`, { token: guest.token })).status).toBe(404);
  });

  it("keeps the higher role when a member accepts", async () => {
    const owner = await signIn();
    const editor = await signIn();
    const viewer = await signIn();
    const newcomer = await signIn();
    const projectId = await createProject(owner);
    await addMember(projectId, editor.userId, "editor");
    await addMember(projectId, viewer.userId, "viewer");

    // A lower role changes nothing and leaves the invite for someone else.
    const viewerInvite = (await invite(owner, projectId, "viewer")).body.code;
    expect((await accept(editor, viewerInvite)).body).toEqual({ projectId, role: "editor" });
    expect((await accept(owner, viewerInvite)).body).toEqual({ projectId, role: "owner" });
    expect((await accept(newcomer, viewerInvite)).body).toEqual({ projectId, role: "viewer" });

    const editorInvite = (await invite(owner, projectId, "editor")).body.code;
    expect((await accept(viewer, editorInvite)).body).toEqual({ projectId, role: "editor" });
    expect((await addTask(viewer, projectId)).status).toBe(201);
  });
});

describe("Members", () => {
  it("lets only the owner change roles, never their own", async () => {
    const owner = await signIn();
    const member = await signIn();
    const other = await signIn();
    const outsider = await signIn();
    const projectId = await createProject(owner);
    await join(owner, member, projectId, "editor");
    await join(owner, other, projectId, "editor");
    const patch = (user: User, userId: string, role: string) =>
      call("PATCH", `/v1/projects/${projectId}/members/${userId}`, { token: user.token, body: { role } });

    const changed = await patch(owner, member.userId, "viewer");
    expect(changed.status).toBe(200);
    expect(changed.body).toMatchObject({ userId: member.userId, role: "viewer" });
    expect((await addTask(member, projectId)).status).toBe(403);

    expect((await patch(other, member.userId, "editor")).status).toBe(403);
    expect((await patch(outsider, member.userId, "editor")).status).toBe(404);
    const own = await patch(owner, owner.userId, "viewer");
    expect(own.status).toBe(400);
    expect(own.body.error.code).toBe("cannot_change_owner");
    expect((await patch(owner, member.userId, "owner")).status).toBe(400);
    expect((await patch(owner, outsider.userId, "viewer")).status).toBe(404);
  });

  it("removes a member and their copy of the project", async () => {
    const owner = await signIn();
    const member = await signIn();
    const projectId = await createProject(owner);
    const sectionId = uuid();
    await push(owner.token, [{ op: "upsert", entity: "section", data: { id: sectionId, projectId, name: "عمود", updatedAt: 1 } }]);
    await join(owner, member, projectId);
    const task = (await addTask(owner, projectId, { assigneeId: member.userId })).body.id as string;
    const commentId = (await comment(member, task)).body.id as string;
    const reminderId = uuid();
    await push(member.token, [
      { op: "upsert", entity: "reminder", data: { id: reminderId, taskId: task, kind: "prayer", prayer: "isha", updatedAt: 1 } },
    ]);
    const memberCursor = (await pullAll(member.token)).cursor;
    const ownerCursor = (await pullAll(owner.token)).cursor;

    const removed = await call("DELETE", `/v1/projects/${projectId}/members/${member.userId}`, { token: owner.token });
    expect(removed.status).toBe(204);

    const memberView = await pullAll(member.token, memberCursor);
    expect(memberView.changes.map((c) => [c.entity, c.id, c.op]).sort()).toEqual(
      [
        ["comment", commentId, "delete"],
        ["project", projectId, "delete"],
        ["reminder", reminderId, "delete"],
        ["section", sectionId, "delete"],
        ["task", task, "delete"],
      ].sort(),
    );
    expect((await call("GET", `/v1/projects/${projectId}`, { token: member.token })).status).toBe(404);
    expect((await call("GET", `/v1/tasks/${task}`, { token: member.token })).status).toBe(404);

    const ownerView = await pullAll(owner.token, ownerCursor);
    expect(ownerView.changes.find((c) => c.id === task)!.data!.assigneeId).toBeNull();
    expect(ownerView.changes.map((c) => c.id)).not.toContain(reminderId);

    // New work in the project no longer reaches them.
    await addTask(owner, projectId);
    expect((await pullAll(member.token, memberView.cursor)).changes).toEqual([]);

    // Rejoining brings it all back.
    await join(owner, member, projectId);
    const rejoined = await pullAll(member.token, memberView.cursor);
    expect(rejoined.changes.filter((c) => c.op === "upsert").map((c) => c.entity)).toEqual(
      expect.arrayContaining(["project", "section", "task", "task", "comment"]),
    );
  });

  it("lets a member leave but not the owner", async () => {
    const owner = await signIn();
    const member = await signIn();
    const other = await signIn();
    const projectId = await createProject(owner);
    await join(owner, member, projectId);
    await join(owner, other, projectId);
    const remove = (user: User, userId: string) =>
      call("DELETE", `/v1/projects/${projectId}/members/${userId}`, { token: user.token });

    expect((await remove(member, other.userId)).status).toBe(403);
    const ownerLeaves = await remove(owner, owner.userId);
    expect(ownerLeaves.status).toBe(400);
    expect(ownerLeaves.body.error.code).toBe("owner_cannot_leave");
    expect((await remove(member, owner.userId)).status).toBe(403);

    expect((await remove(member, member.userId)).status).toBe(204);
    expect((await call("GET", "/v1/projects", { token: member.token })).body.projects).toEqual([]);
    expect((await remove(member, member.userId)).status).toBe(404);
    const left = await call("GET", `/v1/projects/${projectId}/members`, { token: owner.token });
    expect(left.body.members.map((m: { userId: string }) => m.userId)).toEqual([owner.userId, other.userId]);
  });
});

describe("Comments", () => {
  it("lets viewers comment but not add tasks", async () => {
    const owner = await signIn();
    const viewer = await signIn();
    const projectId = await createProject(owner);
    await join(owner, viewer, projectId, "viewer");
    const task = (await addTask(owner, projectId)).body.id as string;

    expect((await addTask(viewer, projectId)).status).toBe(403);
    expect((await call("PATCH", `/v1/tasks/${task}`, { token: viewer.token, body: { title: "x" } })).status).toBe(403);
    const created = await comment(viewer, task, "  ملاحظة  ");
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({ taskId: task, authorId: viewer.userId, body: "ملاحظة" });
  });

  it("lists, creates and deletes comments; only the author deletes", async () => {
    const owner = await signIn(undefined, "فهد");
    const editor = await signIn(undefined, "نورة");
    const outsider = await signIn();
    const projectId = await createProject(owner);
    await join(owner, editor, projectId);
    const task = (await addTask(owner, projectId)).body.id as string;

    const first = await comment(owner, task, "الأول");
    const second = await comment(editor, task, "الثاني");
    expect((await comment(owner, task, "")).status).toBe(400);
    expect((await comment(outsider, task)).status).toBe(404);

    const list = async (user: User) => call("GET", `/v1/tasks/${task}/comments`, { token: user.token });
    expect((await list(editor)).body.comments.map((c: { body: string; authorName: string }) => [c.body, c.authorName])).toEqual([
      ["الأول", "فهد"],
      ["الثاني", "نورة"],
    ]);
    expect((await list(outsider)).status).toBe(404);

    const remove = (user: User, id: string) => call("DELETE", `/v1/comments/${id}`, { token: user.token });
    expect((await remove(editor, first.body.id)).status).toBe(403);
    expect((await remove(outsider, first.body.id)).status).toBe(404);
    expect((await remove(owner, first.body.id)).status).toBe(204);
    expect((await remove(owner, first.body.id)).status).toBe(404);
    expect((await list(owner)).body.comments.map((c: { id: string }) => c.id)).toEqual([second.body.id]);

    // The delete reaches other members through sync.
    const synced = (await pullAll(editor.token)).changes.find((c) => c.id === first.body.id);
    expect(synced!.op).toBe("delete");
  });
});
