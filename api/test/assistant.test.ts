import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { Assistant } from "../src/assistant";
import { dayIn } from "../src/data/dates";
import { appleToken, call, push, signIn, testAppleKeys, testGoogleKeys, uuid } from "./helpers";

const assistant = new Assistant(env, { apple: testAppleKeys, google: testGoogleKeys });

function value<T>(outcome: { ok: true; value: T } | { ok: false; error: { code: string; message: string } }): T {
  if (!outcome.ok) throw new Error(`${outcome.error.code}: ${outcome.error.message}`);
  return outcome.value;
}

describe("Assistant (MCP backend)", () => {
  it("links the same Zimam account when signing in from the web", async () => {
    const app = await signIn("apple-mcp-1");
    const token = await appleToken("apple-mcp-1", { audience: "app.zimam.ios.web", nonce: "handle-1" });
    expect(value(await assistant.signInWithApple(token, "handle-1")).userId).toBe(app.userId);
    const replay = await assistant.signInWithApple(token, "another-handle");
    expect(replay.ok).toBe(false);
  });

  it("creates, lists, updates and completes tasks in assistant terms", async () => {
    const { userId } = await signIn();
    const created = value(
      await assistant.createTask(userId, {
        title: "مراجعة العقد",
        dueDate: "2026-10-13",
        duePrayer: "maghrib",
        duePrayerOffset: 20,
        priority: "high",
        tags: ["عمل"],
      }),
    );
    expect(created).toMatchObject({
      priority: "high",
      status: "todo",
      due: { date: "2026-10-13", hijri: "٢ جمادى الأولى ١٤٤٨", gregorian: "١٣ أكتوبر ٢٠٢٦" },
      prayer: { prayer: "maghrib", offsetMinutes: 20, text: "بعد المغرب بـ٢٠ د" },
    });

    // A task with a time gets «عند الموعد» for whoever added it; an all-day one gets none.
    const other = await signIn();
    value(await assistant.createTask(other.userId, { title: "بلا وقت", dueDate: "2026-10-13" }));
    const reminders = `SELECT task_id, kind, offset_minutes FROM reminders WHERE user_id = ?`;
    expect((await env.DB.prepare(reminders).bind(userId).all()).results).toEqual([
      { task_id: created.id, kind: "relative", offset_minutes: 0 },
    ]);
    expect((await env.DB.prepare(reminders).bind(other.userId).all()).results).toEqual([]);

    const updated = value(await assistant.updateTask(userId, created.id, { dueDate: "2026-10-14", priority: "low" }));
    expect(updated).toMatchObject({ priority: "low", title: "مراجعة العقد", due: { date: "2026-10-14" } });

    expect(value(await assistant.listTasks(userId, { query: "مراجعه" })).map((t) => t.id)).toEqual([created.id]);
    const done = value(await assistant.completeTask(userId, created.id));
    expect(done.status).toBe("done");
    expect(done.completedAt).toMatch(/^\d{4}-/);
    expect(value(await assistant.listTasks(userId, {}))).toEqual([]);
    expect(value(await assistant.listTasks(userId, { status: "done" })).map((t) => t.id)).toEqual([created.id]);
  });

  it("adds the next occurrence when it completes a repeating task, once, with the reminders moved", async () => {
    const { token, userId } = await signIn();
    // Thursday 5 March 2099, weekly on Thursdays, three times left, over two days. Far ahead, since
    // the next occurrence is never before today.
    const task = value(
      await assistant.createTask(userId, {
        title: "المراجعة الأسبوعية",
        startDate: "2099-03-04",
        dueDate: "2099-03-05",
        dueTime: "09:00",
        recurrence: "FREQ=WEEKLY;BYDAY=TH;COUNT=3",
      }),
    );
    const place = { latitude: 24.7, longitude: 46.6, radius: 200, name: "العمل", trigger: "arrive", placeId: null };
    await push(token, [
      { op: "upsert", entity: "reminder", data: { id: uuid(), taskId: task.id, kind: "time", at: "2099-03-05T08:00:00+03:00", updatedAt: 1000 } },
      {
        op: "upsert",
        entity: "reminder",
        data: { id: uuid(), taskId: task.id, kind: "location", location: place, at: "2099-03-05T10:00:00+03:00", firedAt: 1000, updatedAt: 1000 },
      },
    ]);

    expect(value(await assistant.completeTask(userId, task.id)).status).toBe("done");
    const [next, ...more] = value(await assistant.listTasks(userId, {}));
    expect(more).toEqual([]);
    expect(next).toMatchObject({
      title: "المراجعة الأسبوعية",
      status: "todo",
      due: { date: "2099-03-12", time: "09:00" },
      start: { date: "2099-03-11" },
      recurrence: "FREQ=WEEKLY;BYDAY=TH;COUNT=2",
      completedAt: null,
    });
    const { results } = await env.DB.prepare(
      `SELECT kind, at, offset_minutes, fired_at FROM reminders WHERE task_id = ? AND user_id = ? ORDER BY kind`,
    )
      .bind(next!.id, userId)
      .all();
    expect(results).toEqual([
      { kind: "location", at: "2099-03-12T10:00:00+03:00", offset_minutes: null, fired_at: null },
      { kind: "relative", at: null, offset_minutes: 0, fired_at: null },
      { kind: "time", at: "2099-03-12T08:00:00+03:00", offset_minutes: null, fired_at: null },
    ]);

    // Completing it again, or reopening and completing it, adds nothing more.
    value(await assistant.completeTask(userId, task.id));
    value(await assistant.updateTask(userId, task.id, { status: "todo" }));
    value(await assistant.updateTask(userId, task.id, { status: "done" }));
    expect(value(await assistant.listTasks(userId, {})).map((t) => t.id)).toEqual([next!.id]);

    // The last of the series adds none.
    value(await assistant.updateTask(userId, next!.id, { status: "done" }));
    const [last] = value(await assistant.listTasks(userId, {}));
    expect(last).toMatchObject({ due: { date: "2099-03-19" }, recurrence: "FREQ=WEEKLY;BYDAY=TH;COUNT=1" });
    value(await assistant.completeTask(userId, last!.id));
    expect(value(await assistant.listTasks(userId, {}))).toEqual([]);
  });

  it("schedules an overdue repeating task's next occurrence from today", async () => {
    const { userId } = await signIn();
    const task = value(await assistant.createTask(userId, { title: "سقي الزرع", dueDate: "2026-01-01", recurrence: "FREQ=DAILY" }));
    value(await assistant.completeTask(userId, task.id));
    const [next] = value(await assistant.listTasks(userId, {}));
    expect(next).toMatchObject({ title: "سقي الزرع", due: { date: dayIn("Asia/Riyadh") }, recurrence: "FREQ=DAILY" });
  });

  it("answers a completion as done when adding the next occurrence fails", async () => {
    const { userId } = await signIn();
    const task = value(await assistant.createTask(userId, { title: "سقي الزرع", recurrence: "FREQ=DAILY" }));
    // D1 fails once the copy is written, on the reminders to move onto it.
    const db = {
      prepare: (sql: string) => {
        if (sql.includes("FROM reminders WHERE task_id = ? AND user_id = ?")) throw new Error("D1 is unavailable");
        return env.DB.prepare(sql);
      },
      batch: (statements: D1PreparedStatement[]) => env.DB.batch(statements),
    } as Partial<D1Database> as D1Database;
    const failing = new Assistant({ ...env, DB: db }, { apple: testAppleKeys, google: testGoogleKeys });
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      expect(value(await failing.completeTask(userId, task.id)).status).toBe("done");
      expect(logged).toHaveBeenCalledWith("assistant: could not add the next occurrence", expect.any(Error));
    } finally {
      logged.mockRestore();
    }
    const stored = await env.DB.prepare(`SELECT status FROM tasks WHERE id = ?`).bind(task.id).first<{ status: string }>();
    expect(stored!.status).toBe("done");
  });

  it("keeps users apart and validates input", async () => {
    const a = await signIn();
    const b = await signIn();
    const task = value(await assistant.createTask(a.userId, { title: "خاصة" }));
    const other = await assistant.updateTask(b.userId, task.id, { title: "x" });
    expect(other).toEqual({ ok: false, error: { code: "not_found", message: "Task not found" } });
    expect((await assistant.createTask(a.userId, { dueDate: "2026-10-13" })).ok).toBe(false);
    expect((await assistant.createTask(a.userId, { title: "x", dueTime: "25:00" })).ok).toBe(false);
    expect((await assistant.updateTask(a.userId, "not-a-uuid", { title: "x" })).ok).toBe(false);
  });

  it("lists projects with counts and puts tasks in them by id", async () => {
    const { token, userId } = await signIn();
    const project = await call("POST", "/v1/projects", { token, body: { name: "العمل" } });
    const task = value(await assistant.createTask(userId, { title: "تقرير", projectId: project.body.id }));
    expect(task.project).toBe("العمل");
    expect(value(await assistant.listProjects(userId))).toEqual([
      expect.objectContaining({ name: "العمل", role: "owner", taskCount: 1, doneCount: 0 }),
    ]);
    expect((await assistant.createTask(userId, { title: "x", projectId: uuid() })).ok).toBe(false);
  });

  it("builds an agenda in both calendars with prayer times and overdue tasks", async () => {
    const { token, userId } = await signIn();
    await call("PATCH", "/v1/me", {
      token,
      body: { settings: { timeZone: "Asia/Riyadh", location: { latitude: 24.7136, longitude: 46.6753 } } },
    });
    await assistant.createTask(userId, { title: "متأخرة", dueDate: "2026-10-10" });
    await assistant.createTask(userId, { title: "اليوم", dueDate: "2026-10-13" });
    await assistant.createTask(userId, { title: "غداً", dueDate: "2026-10-14" });

    const agenda = value(await assistant.getAgenda(userId, { from: "2026-10-13", days: 2 }));
    expect(agenda.hasLocation).toBe(true);
    expect(agenda.overdue.map((t) => t.title)).toEqual(["متأخرة"]);
    expect(agenda.days.map((d) => [d.date, d.weekday, d.label, d.tasks.map((t) => t.title)])).toEqual([
      ["2026-10-13", "الثلاثاء", "٢ جمادى الأولى ١٤٤٨، ١٣ أكتوبر ٢٠٢٦", ["اليوم"]],
      ["2026-10-14", "الأربعاء", "٣ جمادى الأولى ١٤٤٨، ١٤ أكتوبر ٢٠٢٦", ["غداً"]],
    ]);
    const prayers = agenda.days[0]!.prayers!;
    const order = [prayers.fajr, prayers.dhuhr, prayers.asr, prayers.maghrib, prayers.isha];
    expect(order).toEqual([...order].sort());
    expect(prayers.fajr).toMatch(/^0[45]:\d\d$/);
    expect(prayers.maghrib).toMatch(/^17:\d\d$/);
  });

  it("gives Isha 120 minutes after Maghrib in Ramadan under Umm al-Qura", async () => {
    const { token, userId } = await signIn();
    await call("PATCH", "/v1/me", { token, body: { settings: { location: { latitude: 21.4225, longitude: 39.8262 } } } });
    const minutes = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3));
    const gap = async (day: string) => {
      const p = value(await assistant.getAgenda(userId, { from: day })).days[0]!.prayers!;
      return minutes(p.isha) - minutes(p.maghrib);
    };
    expect(await gap("2026-10-13")).toBe(90);
    expect(await gap("2027-02-15")).toBe(120); // 8 Ramadan 1448
  });

  it("omits prayer times until a location is saved", async () => {
    const { userId } = await signIn();
    const agenda = value(await assistant.getAgenda(userId, {}));
    expect(agenda.hasLocation).toBe(false);
    expect(agenda.days[0]!.prayers).toBeNull();
    expect(agenda.timeZone).toBe("Asia/Riyadh");
  });

  it("refuses accounts that were deleted", async () => {
    const { token, userId } = await signIn();
    await call("DELETE", "/v1/me", { token });
    expect(await assistant.listTasks(userId, {})).toMatchObject({ ok: false, error: { code: "unauthorized" } });
  });
});

describe("Assistant places (MCP backend)", () => {
  it("lists saved places by name and adds reminders at them, alone or with a time", async () => {
    const { userId, token } = await signIn();
    const other = await signIn();
    const home = uuid();
    const theirs = uuid();
    const place = (id: string, name: string) => ({
      op: "upsert",
      entity: "place",
      data: { id, name, latitude: 24.7136, longitude: 46.6753, radius: 250, updatedAt: 1000 },
    });
    await call("POST", "/v1/sync", { token, body: { mutations: [place(home, "البيت")] } });
    await call("POST", "/v1/sync", { token: other.token, body: { mutations: [place(theirs, "الاستراحة")] } });

    expect(value(await assistant.listPlaces(userId))).toEqual([{ id: home, name: "البيت", radiusMeters: 250 }]);

    const task = value(await assistant.createTask(userId, { title: "شراء الخبز" }));
    // Found by name, ignoring alef forms and diacritics.
    const alone = value(await assistant.addPlaceReminder(userId, { taskId: task.id, place: "البَيت" }));
    expect(alone).toMatchObject({ taskId: task.id, place: "البيت", trigger: "arrive", at: null, text: "عند الوصول إلى البيت" });

    const timed = value(
      await assistant.addPlaceReminder(userId, { taskId: task.id, place: home, trigger: "leave", date: "2026-10-13", time: "17:00" }),
    );
    expect(timed).toMatchObject({
      at: { date: "2026-10-13", time: "17:00", hijri: "٢ جمادى الأولى ١٤٤٨" },
      text: "عند مغادرة البيت أو في الوقت المحدد، أيهما أسبق",
    });

    const pulled = await call("GET", "/v1/sync?cursor=0", { token });
    const reminder = pulled.body.changes.find((c: { id: string }) => c.id === timed.id).data;
    expect(reminder).toMatchObject({
      kind: "location",
      at: "2026-10-13T17:00:00+03:00",
      firedAt: null,
      location: { latitude: 24.7136, longitude: 46.6753, radius: 250, name: "البيت", trigger: "leave", placeId: home },
    });

    const missing = await assistant.addPlaceReminder(userId, { taskId: task.id, place: "الاستراحة" });
    expect(missing.ok).toBe(false);
    if (!missing.ok) expect(missing.error.message).toContain("«البيت»");
    expect((await assistant.addPlaceReminder(userId, { taskId: task.id, place: theirs })).ok).toBe(false);
    expect((await assistant.addPlaceReminder(userId, { taskId: uuid(), place: home })).ok).toBe(false);
    expect((await assistant.addPlaceReminder(userId, { taskId: task.id, place: home, time: "17:00" })).ok).toBe(false);
  });
});
