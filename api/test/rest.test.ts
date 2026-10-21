import { describe, expect, it } from "vitest";
import { addMember, call, push, signIn, uuid } from "./helpers";

describe("Tasks API", () => {
  it("creates, reads, updates, completes and deletes an inbox task", async () => {
    const { token, userId } = await signIn();
    const created = await call("POST", "/v1/tasks", {
      token,
      body: { title: "مراجعة العقد", dueDate: "2026-10-15", duePrayer: "maghrib", duePrayerOffset: 20, tags: ["عمل"] },
    });
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({ ownerId: userId, projectId: null, status: "todo", duePrayer: "maghrib" });
    const id = created.body.id;

    const patched = await call("PATCH", `/v1/tasks/${id}`, { token, body: { priority: 3, ownerId: "someone-else" } });
    expect(patched.status).toBe(200);
    expect(patched.body).toMatchObject({ priority: 3, ownerId: userId, title: "مراجعة العقد" });

    const done = await call("POST", `/v1/tasks/${id}/complete`, { token });
    expect(done.body.status).toBe("done");
    expect(done.body.completedAt).toBeTypeOf("number");

    expect((await call("DELETE", `/v1/tasks/${id}`, { token })).status).toBe(204);
    expect((await call("GET", `/v1/tasks/${id}`, { token })).status).toBe(404);
  });

  it("lists a task's reminders for their owner only", async () => {
    const owner = await signIn();
    const editor = await signIn();
    const project = await call("POST", "/v1/projects", { token: owner.token, body: { name: "مشترك" } });
    await addMember(project.body.id, editor.userId, "editor");
    const task = await call("POST", "/v1/tasks", { token: owner.token, body: { title: "اجتماع", projectId: project.body.id, dueDate: "2026-10-15", dueTime: "10:00" } });
    const taskId = task.body.id;
    const mine = crypto.randomUUID();
    const theirs = crypto.randomUUID();
    const sync = (token: string, data: Record<string, unknown>) =>
      call("POST", "/v1/sync", { token, body: { mutations: [{ op: "upsert", entity: "reminder", data: { taskId, updatedAt: Date.now(), ...data } }] } });
    expect((await sync(owner.token, { id: mine, kind: "relative", offsetMinutes: -15 })).body.results[0].status).toBe("applied");
    expect((await sync(editor.token, { id: theirs, kind: "prayer", prayer: "asr", offsetMinutes: 0 })).body.results[0].status).toBe("applied");

    const list = await call("GET", `/v1/tasks/${taskId}/reminders`, { token: owner.token });
    expect(list.status).toBe(200);
    expect(list.body.reminders.map((r: { id: string; kind: string; offsetMinutes: number }) => [r.id, r.kind, r.offsetMinutes])).toEqual([[mine, "relative", -15]]);
    expect((await call("GET", `/v1/tasks/${taskId}/reminders`, { token: editor.token })).body.reminders.map((r: { id: string }) => r.id)).toEqual([theirs]);

    const stranger = await signIn();
    expect((await call("GET", `/v1/tasks/${taskId}/reminders`, { token: stranger.token })).status).toBe(404);
  });

  it("validates input", async () => {
    const { token } = await signIn();
    expect((await call("POST", "/v1/tasks", { token, body: { title: "" } })).status).toBe(400);
    expect((await call("POST", "/v1/tasks", { token, body: { title: "x", dueDate: "2026-13-40" } })).status).toBe(400);
    expect((await call("POST", "/v1/tasks", { token, body: { title: "x", dueTime: "25:00" } })).status).toBe(400);
  });

  it("hides one user's tasks from another", async () => {
    const a = await signIn();
    const b = await signIn();
    const task = await call("POST", "/v1/tasks", { token: a.token, body: { title: "خاصة" } });
    expect((await call("GET", `/v1/tasks/${task.body.id}`, { token: b.token })).status).toBe(404);
    expect((await call("PATCH", `/v1/tasks/${task.body.id}`, { token: b.token, body: { title: "x" } })).status).toBe(404);
    expect((await call("GET", "/v1/tasks", { token: b.token })).body.tasks).toEqual([]);
  });

  it("searches Arabic text regardless of diacritics, letter forms and digits", async () => {
    const { token } = await signIn();
    await call("POST", "/v1/tasks", { token, body: { title: "مُراجَعة العقد ١٢", notes: "مع الإدارة" } });
    await call("POST", "/v1/tasks", { token, body: { title: "شراء هدية" } });
    for (const q of ["مراجعه", "عقد 12", "الاداره"]) {
      const res = await call("GET", `/v1/tasks?q=${encodeURIComponent(q)}`, { token });
      expect(res.body.tasks.map((t: { title: string }) => t.title), q).toEqual(["مُراجَعة العقد ١٢"]);
    }
    const literal = await call("GET", `/v1/tasks?q=${encodeURIComponent("%")}`, { token });
    expect(literal.body.tasks).toEqual([]);
  });

  it("filters by date range, status and inbox, dated tasks first", async () => {
    const { token } = await signIn();
    const project = await call("POST", "/v1/projects", { token, body: { name: "العمل" } });
    await call("POST", "/v1/tasks", { token, body: { title: "بلا تاريخ" } });
    await call("POST", "/v1/tasks", { token, body: { title: "الخميس", dueDate: "2026-10-15" } });
    await call("POST", "/v1/tasks", { token, body: { title: "الأربعاء", dueDate: "2026-10-14" } });
    await call("POST", "/v1/tasks", { token, body: { title: "في المشروع", projectId: project.body.id, status: "done" } });

    const titles = async (query: string) =>
      (await call("GET", `/v1/tasks${query}`, { token })).body.tasks.map((t: { title: string }) => t.title);
    expect(await titles("")).toEqual(["الأربعاء", "الخميس", "بلا تاريخ", "في المشروع"]);
    expect(await titles("?dueFrom=2026-10-15&dueTo=2026-10-31")).toEqual(["الخميس"]);
    expect(await titles("?projectId=inbox")).toEqual(["الأربعاء", "الخميس", "بلا تاريخ"]);
    expect(await titles("?status=open")).toEqual(["الأربعاء", "الخميس", "بلا تاريخ"]);
    expect(await titles(`?projectId=${project.body.id}`)).toEqual(["في المشروع"]);
  });
});

describe("Projects API", () => {
  it("lists projects with counts and role", async () => {
    const { token } = await signIn();
    const project = await call("POST", "/v1/projects", { token, body: { name: "البيت", view: "kanban" } });
    expect(project.status).toBe(201);
    const id = project.body.id;
    await call("POST", "/v1/tasks", { token, body: { title: "١", projectId: id } });
    await call("POST", "/v1/tasks", { token, body: { title: "٢", projectId: id, status: "done" } });

    const list = await call("GET", "/v1/projects", { token });
    expect(list.body.projects).toEqual([expect.objectContaining({ id, name: "البيت", role: "owner", taskCount: 2, doneCount: 1 })]);
  });

  it("lists each project's sections in order, and no one else's", async () => {
    const { token } = await signIn();
    const other = await signIn();
    const project = (await call("POST", "/v1/projects", { token, body: { name: "العمل", view: "kanban" } })).body.id;
    const empty = (await call("POST", "/v1/projects", { token, body: { name: "فارغ" } })).body.id;
    const folder = (await call("POST", "/v1/projects", { token, body: { name: "مجلد", kind: "folder" } })).body.id;
    const foreign = (await call("POST", "/v1/projects", { token: other.token, body: { name: "غريب" } })).body.id;
    const [later, first, gone] = [uuid(), uuid(), uuid()];
    const section = (id: string, projectId: string, name: string, sortOrder: number) => ({
      op: "upsert",
      entity: "section",
      data: { id, projectId, name, sortOrder, updatedAt: 1 },
    });
    await push(token, [
      section(later, project, "قيد العمل", 2),
      section(first, project, "للعمل", 1),
      section(gone, project, "محذوف", 3),
    ]);
    await push(token, [{ op: "delete", entity: "section", id: gone, updatedAt: 2 }]);
    await push(other.token, [section(uuid(), foreign, "عمود", 1)]);

    const list = (await call("GET", "/v1/projects", { token })).body.projects as {
      id: string;
      sections: { id: string; projectId: string; name: string }[];
    }[];
    const byId = new Map(list.map((p) => [p.id, p]));
    expect(byId.get(project)!.sections.map((s) => s.id)).toEqual([first, later]);
    expect(byId.get(project)!.sections[0]).toMatchObject({ projectId: project, name: "للعمل", sortOrder: 1 });
    expect(byId.get(empty)!.sections).toEqual([]);
    expect(byId.get(folder)!.sections).toEqual([]);
    expect(byId.has(foreign)).toBe(false);
  });

  it("lets editors add tasks, stops viewers and outsiders", async () => {
    const owner = await signIn();
    const editor = await signIn();
    const viewer = await signIn();
    const outsider = await signIn();
    const project = await call("POST", "/v1/projects", { token: owner.token, body: { name: "مشترك" } });
    const projectId = project.body.id;
    await addMember(projectId, editor.userId, "editor");
    await addMember(projectId, viewer.userId, "viewer");

    const add = (token: string) => call("POST", "/v1/tasks", { token, body: { title: "مهمة", projectId } });
    expect((await add(editor.token)).status).toBe(201);
    expect((await add(viewer.token)).status).toBe(403);
    expect((await add(outsider.token)).status).toBe(403);
    expect((await call("GET", `/v1/projects/${projectId}`, { token: viewer.token })).body.role).toBe("viewer");
    expect((await call("GET", `/v1/projects/${projectId}`, { token: outsider.token })).status).toBe(404);
    expect((await call("DELETE", `/v1/projects/${projectId}`, { token: editor.token })).status).toBe(403);
  });

  it("assigns only to project members", async () => {
    const owner = await signIn();
    const member = await signIn();
    const stranger = await signIn();
    const project = await call("POST", "/v1/projects", { token: owner.token, body: { name: "فريق" } });
    await addMember(project.body.id, member.userId, "editor");
    const assign = (assigneeId: string) =>
      call("POST", "/v1/tasks", { token: owner.token, body: { title: "x", projectId: project.body.id, assigneeId } });
    expect((await assign(member.userId)).status).toBe(201);
    expect((await assign(stranger.userId)).status).toBe(400);
  });

  it("deletes a project with its tasks", async () => {
    const { token } = await signIn();
    const project = await call("POST", "/v1/projects", { token, body: { name: "مؤقت" } });
    const task = await call("POST", "/v1/tasks", { token, body: { title: "x", projectId: project.body.id } });
    expect((await call("DELETE", `/v1/projects/${project.body.id}`, { token })).status).toBe(204);
    expect((await call("GET", `/v1/tasks/${task.body.id}`, { token })).status).toBe(404);
    expect((await call("GET", "/v1/projects", { token })).body.projects).toEqual([]);
  });
});
