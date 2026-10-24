import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { MAX_CLOCK_SKEW_MS } from "../src/data/mutations";
import { addMember, call, pullAll, push, signIn, uuid } from "./helpers";

const project = (id: string, updatedAt: number, extra = {}) => ({
  op: "upsert",
  entity: "project",
  data: { id, name: "مشروع", updatedAt, ...extra },
});
const task = (id: string, updatedAt: number, extra = {}) => ({
  op: "upsert",
  entity: "task",
  data: { id, title: "مهمة", updatedAt, ...extra },
});

describe("Sync", () => {
  it("round-trips offline edits to another device", async () => {
    const { token } = await signIn();
    const projectId = uuid().toUpperCase(); // Swift sends uppercase
    const taskId = uuid();
    const reminderId = uuid();
    const results = await push(token, [
      project(projectId, 1000),
      task(taskId, 1000, { projectId, dueDate: "2026-10-15" }),
      {
        op: "upsert",
        entity: "reminder",
        data: { id: reminderId, taskId, kind: "prayer", prayer: "asr", offsetMinutes: 20, updatedAt: 1000 },
      },
    ]);
    expect(results.map((r) => r.status)).toEqual(["applied", "applied", "applied"]);
    expect(results[0]!.id).toBe(projectId.toLowerCase());

    const pulled = await pullAll(token);
    expect(pulled.hasMore).toBe(false);
    expect(pulled.changes.map((c) => [c.entity, c.op])).toEqual([
      ["project", "upsert"],
      ["task", "upsert"],
      ["reminder", "upsert"],
    ]);
    expect(pulled.changes[1]!.data).toMatchObject({ projectId: projectId.toLowerCase(), dueDate: "2026-10-15" });

    // Nothing new after the cursor.
    expect((await pullAll(token, pulled.cursor)).changes).toEqual([]);
  });

  it("keeps the newest write and reports stale ones", async () => {
    const { token } = await signIn();
    const id = uuid();
    await push(token, [task(id, 2000, { title: "الأحدث" })]);
    const [stale] = await push(token, [task(id, 1000, { title: "أقدم" })]);
    expect(stale!.status).toBe("stale");
    const [retry] = await push(token, [task(id, 2000, { title: "الأحدث" })]);
    expect(retry!.status).toBe("applied");
    const { changes } = await pullAll(token);
    expect(changes.find((c) => c.id === id)!.data!.title).toBe("الأحدث");
  });

  it("caps versions from a clock that runs ahead, and keeps rows already ahead editable", async () => {
    const { token } = await signIn();
    const stored = async (id: string) =>
      (await env.DB.prepare(`SELECT updated_at FROM tasks WHERE id = ?`).bind(id).first<{ updated_at: number }>())!.updated_at;
    const year = 365 * 24 * 60 * 60 * 1000;

    // A device a year ahead: stored a few minutes ahead at most, so it does not win for a year.
    const ahead = uuid();
    const before = Date.now();
    expect((await push(token, [task(ahead, before + year, { title: "من جهاز متقدم" })]))[0]!.status).toBe("applied");
    expect(await stored(ahead)).toBeLessThanOrEqual(Date.now() + MAX_CLOCK_SKEW_MS);
    expect((await push(token, [task(ahead, before + MAX_CLOCK_SKEW_MS + 60_000, { title: "بعد دقائق" })]))[0]!.status).toBe("applied");

    // The largest safe version leaves room for the next one.
    const frozen = uuid();
    await push(token, [task(frozen, Number.MAX_SAFE_INTEGER)]);
    const version = await stored(frozen);
    expect((await push(token, [task(frozen, version + 1, { title: "تعديل" })]))[0]!.status).toBe("applied");

    // A row stored ahead before the cap: one past it still goes through, and so does a delete.
    const old = uuid();
    await push(token, [task(old, 1000)]);
    await env.DB.prepare(`UPDATE tasks SET updated_at = ? WHERE id = ?`).bind(before + year, old).run();
    expect((await push(token, [task(old, before + year + 1, { title: "تعديل" })]))[0]!.status).toBe("applied");
    expect(await stored(old)).toBe(before + year + 1);
    const [deleted] = await push(token, [{ op: "delete", entity: "task", id: old, updatedAt: Number.MAX_SAFE_INTEGER }]);
    expect(deleted!.status).toBe("applied");
    expect(await stored(old)).toBe(before + year + 2);
  });

  it("returns only the latest state of each record, paged", async () => {
    const { token } = await signIn();
    const ids = [uuid(), uuid(), uuid()];
    await push(token, ids.map((id, i) => task(id, 1000 + i)));
    await push(token, [task(ids[0]!, 5000, { title: "معدّلة" })]);

    const first = await call("GET", "/v1/sync?cursor=0&limit=2", { token });
    expect(first.body.hasMore).toBe(true);
    expect(first.body.changes.map((c: { id: string }) => c.id)).toEqual([ids[1], ids[2]]);
    const rest = await pullAll(token, first.body.cursor);
    expect(rest.changes.map((c) => [c.id, c.data!.title])).toEqual([[ids[0], "معدّلة"]]);
  });

  it("propagates deletes, including subtasks and reminders", async () => {
    const { token } = await signIn();
    const parent = uuid();
    const child = uuid();
    const reminder = uuid();
    await push(token, [
      task(parent, 1000),
      task(child, 1000, { parentId: parent }),
      { op: "upsert", entity: "reminder", data: { id: reminder, taskId: child, kind: "time", at: "2026-10-15T09:00:00+03:00", updatedAt: 1000 } },
    ]);
    const { cursor } = await pullAll(token);
    const [deleted] = await push(token, [{ op: "delete", entity: "task", id: parent, updatedAt: 2000 }]);
    expect(deleted!.status).toBe("applied");

    const after = await pullAll(token, cursor);
    expect(after.changes.map((c) => [c.entity, c.id, c.op]).sort()).toEqual(
      [
        ["reminder", reminder, "delete"],
        ["task", child, "delete"],
        ["task", parent, "delete"],
      ].sort(),
    );
    // Editing a deleted task is refused; deleting again is harmless.
    expect((await push(token, [task(parent, 3000)]))[0]!.status).toBe("gone");
    expect((await push(token, [{ op: "delete", entity: "task", id: parent, updatedAt: 4000 }]))[0]!.status).toBe("applied");
  });

  it("shares project changes with members only", async () => {
    const owner = await signIn();
    const member = await signIn();
    const outsider = await signIn();
    const projectId = uuid();
    await push(owner.token, [project(projectId, 1000)]);
    await addMember(projectId, member.userId, "editor");
    const taskId = uuid();
    await push(member.token, [task(taskId, 1000, { projectId })]);

    const seen = (await pullAll(owner.token)).changes.map((c) => c.id);
    expect(seen).toEqual(expect.arrayContaining([projectId, taskId]));
    expect((await pullAll(outsider.token)).changes).toEqual([]);
    expect((await push(outsider.token, [task(taskId, 2000, { projectId })]))[0]!.status).toBe("forbidden");
  });

  it("keeps reminders personal within a shared project", async () => {
    const owner = await signIn();
    const member = await signIn();
    const projectId = uuid();
    const taskId = uuid();
    await push(owner.token, [project(projectId, 1000), task(taskId, 1000, { projectId })]);
    await addMember(projectId, member.userId, "viewer");
    const reminderId = uuid();
    const [r] = await push(member.token, [
      { op: "upsert", entity: "reminder", data: { id: reminderId, taskId, kind: "prayer", prayer: "fajr", updatedAt: 1000 } },
    ]);
    expect(r!.status).toBe("applied");
    expect((await pullAll(owner.token)).changes.map((c) => c.id)).not.toContain(reminderId);
    expect((await pullAll(member.token)).changes.map((c) => c.id)).toContain(reminderId);
  });

  it("sends reminders relative to the task's time only to apps that ask for them", async () => {
    const { token } = await signIn();
    const taskId = uuid();
    await push(token, [task(taskId, 1000, { dueDate: "2027-01-10", dueTime: "15:00" })]);
    const relative = uuid();
    const results = await push(token, [
      { op: "upsert", entity: "reminder", data: { id: relative, taskId, kind: "relative", offsetMinutes: -15, updatedAt: 1000 } },
      // Relative reminders come at or before the task's time, up to a week, and need an offset.
      { op: "upsert", entity: "reminder", data: { id: uuid(), taskId, kind: "relative", offsetMinutes: 15, updatedAt: 1000 } },
      { op: "upsert", entity: "reminder", data: { id: uuid(), taskId, kind: "relative", offsetMinutes: -10081, updatedAt: 1000 } },
      { op: "upsert", entity: "reminder", data: { id: uuid(), taskId, kind: "relative", updatedAt: 1000 } },
      // A prayer reminder still stays within 12 hours of its prayer.
      { op: "upsert", entity: "reminder", data: { id: uuid(), taskId, kind: "prayer", prayer: "asr", offsetMinutes: -800, updatedAt: 1000 } },
    ]);
    expect(results.map((r) => r.status)).toEqual(["applied", "invalid", "invalid", "invalid", "invalid"]);

    const old = await pullAll(token);
    expect(old.changes.map((c) => c.id)).not.toContain(relative);
    const asked = await call("GET", "/v1/sync?cursor=0&include=timeline,place,relative", { token });
    const change = (asked.body as { changes: { id: string; data?: Record<string, unknown> }[] }).changes.find((c) => c.id === relative);
    expect(change?.data).toMatchObject({ kind: "relative", offsetMinutes: -15 });
  });

  it("keeps a task's time to one kind: a prayer, or a clock time on its day", async () => {
    const { token } = await signIn();
    const anchored = uuid();
    const undated = uuid();
    await push(token, [
      task(anchored, 1000, { dueDate: "2027-01-10", dueTime: "15:00", duePrayer: "asr" }),
      task(undated, 1000, { dueTime: "15:00" }),
    ]);
    const tasks = new Map((await pullAll(token)).changes.map((c) => [c.id, c.data]));
    expect(tasks.get(anchored)).toMatchObject({ dueTime: null, duePrayer: "asr" });
    expect(tasks.get(undated)).toMatchObject({ dueTime: null });
  });

  it("tells old members when a task moves out of their project", async () => {
    const owner = await signIn();
    const member = await signIn();
    const projectId = uuid();
    const taskId = uuid();
    const subtaskId = uuid();
    await push(owner.token, [
      project(projectId, 1000),
      task(taskId, 1000, { projectId }),
      task(subtaskId, 1000, { projectId, parentId: taskId }),
    ]);
    await addMember(projectId, member.userId, "editor");
    const { cursor } = await pullAll(member.token);

    const [moved] = await push(owner.token, [task(taskId, 2000)]); // to the owner's inbox
    expect(moved!.status).toBe("applied");

    const memberView = await pullAll(member.token, cursor);
    expect(memberView.changes.filter((c) => c.entity === "task").map((c) => [c.id, c.op]).sort()).toEqual(
      [
        [subtaskId, "delete"],
        [taskId, "delete"],
      ].sort(),
    );
    const ownerView = await pullAll(owner.token);
    const sub = ownerView.changes.find((c) => c.id === subtaskId)!;
    expect(sub.op).toBe("upsert");
    expect(sub.data!.projectId).toBeNull();
  });

  it("removes the reminders of whoever cannot see a task where it moves", async () => {
    const owner = await signIn();
    const stays = await signIn(); // a member of both projects
    const leaves = await signIn(); // a member of the first only
    const from = uuid();
    const to = uuid();
    const taskId = uuid();
    const subtaskId = uuid();
    await push(owner.token, [
      project(from, 1000),
      project(to, 1000),
      task(taskId, 1000, { projectId: from }),
      task(subtaskId, 1000, { projectId: from, parentId: taskId }),
    ]);
    await addMember(from, stays.userId, "editor");
    await addMember(to, stays.userId, "viewer");
    await addMember(from, leaves.userId, "viewer");
    const reminder = (id: string, on: string) => ({
      op: "upsert",
      entity: "reminder",
      data: { id, taskId: on, kind: "time", at: "2027-01-10T09:00:00+03:00", updatedAt: 1000 },
    });
    const [mine, kept, gone, goneOnSubtask] = [uuid(), uuid(), uuid(), uuid()];
    await push(owner.token, [reminder(mine, taskId)]);
    await push(stays.token, [reminder(kept, taskId)]);
    await push(leaves.token, [reminder(gone, taskId), reminder(goneOnSubtask, subtaskId)]);
    const { cursor } = await pullAll(leaves.token);

    expect((await push(owner.token, [task(taskId, 2000, { projectId: to })]))[0]!.status).toBe("applied");

    const { results } = await env.DB.prepare(`SELECT id FROM reminders WHERE task_id IN (?, ?) AND deleted_at IS NULL`)
      .bind(taskId, subtaskId)
      .all<{ id: string }>();
    expect(results.map((r) => r.id).sort()).toEqual([mine, kept].sort());
    const leaverView = await pullAll(leaves.token, cursor);
    expect(leaverView.changes.filter((c) => c.entity === "reminder").map((c) => [c.id, c.op]).sort()).toEqual(
      [
        [gone, "delete"],
        [goneOnSubtask, "delete"],
      ].sort(),
    );
  });

  it("applies a full batch of plain edits, and answers a heavier one in part for the client to resend", async () => {
    const { token, userId } = await signIn();
    const plain = Array.from({ length: 200 }, () => task(uuid(), 1000));
    expect((await push(token, plain)).map((r) => r.status)).toEqual(plain.map(() => "applied"));

    // Subtasks nine levels down: each checks every ancestor, so 200 cost more than one push may spend.
    const chain = Array.from({ length: 9 }, () => uuid());
    await push(token, chain.map((id, i) => task(id, 1000, { parentId: i > 0 ? chain[i - 1] : null })));
    const deep = Array.from({ length: 200 }, () => task(uuid(), 1000, { parentId: chain[8] }));
    const first = await push(token, deep);
    expect(first.length).toBeGreaterThan(0);
    expect(first.length).toBeLessThan(deep.length);
    expect(first.every((r) => r.status === "applied")).toBe(true);

    // What had no result was not touched, and goes through when sent again.
    let left = deep.slice(first.length);
    for (let round = 0; left.length > 0; round++) {
      if (round > 10) throw new Error("the push never finished");
      const results = await push(token, left);
      expect(results.every((r) => r.status === "applied")).toBe(true);
      left = left.slice(results.length);
    }
    const { count } = (await env.DB.prepare(`SELECT COUNT(*) AS count FROM tasks WHERE owner_id = ? AND parent_id = ?`)
      .bind(userId, chain[8])
      .first<{ count: number }>())!;
    expect(count).toBe(200);
  });

  it("rejects subtask cycles and cross-project parents", async () => {
    const { token } = await signIn();
    const a = uuid();
    const b = uuid();
    const projectId = uuid();
    await push(token, [project(projectId, 1000), task(a, 1000), task(b, 1000, { parentId: a })]);
    expect((await push(token, [task(a, 2000, { parentId: b })]))[0]!.status).toBe("invalid");
    expect((await push(token, [task(a, 2000, { parentId: a })]))[0]!.status).toBe("invalid");
    expect((await push(token, [task(uuid(), 2000, { parentId: a, projectId })]))[0]!.status).toBe("invalid");
  });

  it("validates each mutation on its own", async () => {
    const { token } = await signIn();
    const results = await push(token, [
      { op: "upsert", entity: "task", data: { id: "not-a-uuid", title: "x", updatedAt: 1 } },
      { op: "explode" },
      { op: "upsert", entity: "reminder", data: { id: uuid(), taskId: uuid(), kind: "time", updatedAt: 1 } },
      task(uuid(), 1),
    ]);
    expect(results.map((r) => r.status)).toEqual(["invalid", "invalid", "invalid", "applied"]);
  });
});
