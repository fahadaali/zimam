import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { Assistant } from "../src/assistant";
import { call, pullAll, push, signIn, testAppleKeys, testGoogleKeys, uuid } from "./helpers";

// Tasks that span days (startDate … dueDate) and the projects' «المخطط الزمني» view.

const task = (id: string, updatedAt: number, extra = {}) => ({
  op: "upsert",
  entity: "task",
  data: { id, title: "رحلة إلى جدة", updatedAt, ...extra },
});
const project = (id: string, updatedAt: number, extra = {}) => ({
  op: "upsert",
  entity: "project",
  data: { id, name: "مشروع", updatedAt, ...extra },
});

const assistant = new Assistant(env, { apple: testAppleKeys, google: testGoogleKeys });

describe("Start dates", () => {
  it("syncs a span and makes a task one-day again with null", async () => {
    const { token } = await signIn();
    const id = uuid();
    const [saved] = await push(token, [task(id, 1000, { dueDate: "2026-10-11", startDate: "2026-10-09" })]);
    expect(saved!.status).toBe("applied");
    let pulled = await pullAll(token);
    expect(pulled.changes[0]!.data).toMatchObject({ startDate: "2026-10-09", dueDate: "2026-10-11" });

    await push(token, [task(id, 2000, { dueDate: "2026-10-11", startDate: null })]);
    pulled = await pullAll(token);
    expect(pulled.changes[0]!.data).toMatchObject({ startDate: null, dueDate: "2026-10-11" });

    // A one-day span (start on the due day) is allowed.
    const [same] = await push(token, [task(id, 3000, { dueDate: "2026-10-11", startDate: "2026-10-11" })]);
    expect(same!.status).toBe("applied");
  });

  it("rejects a start without a due day or after it", async () => {
    const { token } = await signIn();
    const results = await push(token, [
      task(uuid(), 1000, { startDate: "2026-10-09" }),
      task(uuid(), 1000, { startDate: "2026-10-12", dueDate: "2026-10-11" }),
      task(uuid(), 1000, { startDate: "09/10/2026", dueDate: "2026-10-11" }),
    ]);
    expect(results.map((r) => r.status)).toEqual(["invalid", "invalid", "invalid"]);
    expect(results[0]!.message).toContain("startDate");

    expect((await call("POST", "/v1/tasks", { token, body: { title: "x", startDate: "2026-10-09" } })).status).toBe(400);
    const created = await call("POST", "/v1/tasks", { token, body: { title: "x", startDate: "2026-10-09", dueDate: "2026-10-11" } });
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({ startDate: "2026-10-09", dueDate: "2026-10-11" });
    // PATCH merges over the stored task: moving the due day before the start is refused…
    const before = await call("PATCH", `/v1/tasks/${created.body.id}`, { token, body: { dueDate: "2026-10-08" } });
    expect(before.status).toBe(400);
    expect(before.body.error.code).toBe("invalid");
    // …and moving both together is fine.
    const both = await call("PATCH", `/v1/tasks/${created.body.id}`, {
      token,
      body: { startDate: "2026-10-01", dueDate: "2026-10-08" },
    });
    expect(both.status).toBe(200);
    expect(both.body).toMatchObject({ startDate: "2026-10-01", dueDate: "2026-10-08" });
  });

  it("keeps the start day for apps that predate it, while the due day allows it", async () => {
    const { token } = await signIn();
    const id = uuid();
    await push(token, [task(id, 1000, { dueDate: "2026-10-11", startDate: "2026-10-09" })]);

    // An older app edits the title: no startDate in its record, so the span stays.
    await push(token, [task(id, 2000, { title: "رحلة", dueDate: "2026-10-11" })]);
    expect((await pullAll(token)).changes[0]!.data).toMatchObject({ title: "رحلة", startDate: "2026-10-09" });

    // It moves the due day before the start: the span would be invalid, so it is dropped.
    await push(token, [task(id, 3000, { dueDate: "2026-10-05" })]);
    expect((await pullAll(token)).changes[0]!.data).toMatchObject({ startDate: null, dueDate: "2026-10-05" });

    // It clears the due day of another span: the start goes with it.
    const other = uuid();
    await push(token, [task(other, 1000, { dueDate: "2026-10-11", startDate: "2026-10-09" })]);
    await push(token, [task(other, 2000, { dueDate: null })]);
    const data = (await pullAll(token)).changes.find((c) => c.id === other)!.data!;
    expect(data).toMatchObject({ startDate: null, dueDate: null });
  });

  it("gives assistants the start in both calendars and clears it with the due day", async () => {
    const { userId } = await signIn();
    const created = await assistant.createTask(userId, { title: "رحلة", startDate: "2026-10-12", dueDate: "2026-10-14" });
    if (!created.ok) throw new Error(created.error.message);
    expect(created.value.start).toEqual({ date: "2026-10-12", hijri: "١ جمادى الأولى ١٤٤٨", gregorian: "١٢ أكتوبر ٢٠٢٦" });
    expect(created.value.due).toMatchObject({ date: "2026-10-14" });

    const bad = await assistant.updateTask(userId, created.value.id, { startDate: "2026-10-20" });
    expect(bad.ok).toBe(false);

    const cleared = await assistant.updateTask(userId, created.value.id, { dueDate: null });
    if (!cleared.ok) throw new Error(cleared.error.message);
    expect(cleared.value).toMatchObject({ due: null, start: null });
  });
});

describe("Timeline view", () => {
  it("is a project view, sent as it is only to apps that ask for it", async () => {
    const { token } = await signIn();
    const id = uuid();
    const [saved] = await push(token, [project(id, 1000, { view: "timeline" })]);
    expect(saved!.status).toBe("applied");

    const asked = await call("GET", "/v1/sync?cursor=0&include=attachment,timeline", { token });
    expect(asked.body.changes[0].data.view).toBe("timeline");
    // Older apps decode the view strictly and know only list, kanban and calendar.
    expect((await pullAll(token)).changes[0]!.data!.view).toBe("list");

    const rest = await call("GET", `/v1/projects/${id}`, { token });
    expect(rest.body.view).toBe("timeline");
    const patched = await call("PATCH", `/v1/projects/${id}`, { token, body: { view: "kanban" } });
    expect(patched.body.view).toBe("kanban");
    expect((await call("PATCH", `/v1/projects/${id}`, { token, body: { view: "gantt" } })).status).toBe(400);
  });
});
