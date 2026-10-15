import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { Assistant } from "../src/assistant";
import { appleToken, call, signIn, testAppleKeys, uuid } from "./helpers";

const assistant = new Assistant(env, testAppleKeys);

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

    const updated = value(await assistant.updateTask(userId, created.id, { dueDate: "2026-10-14", priority: "low" }));
    expect(updated).toMatchObject({ priority: "low", title: "مراجعة العقد", due: { date: "2026-10-14" } });

    expect(value(await assistant.listTasks(userId, { query: "مراجعه" })).map((t) => t.id)).toEqual([created.id]);
    const done = value(await assistant.completeTask(userId, created.id));
    expect(done.status).toBe("done");
    expect(done.completedAt).toMatch(/^\d{4}-/);
    expect(value(await assistant.listTasks(userId, {}))).toEqual([]);
    expect(value(await assistant.listTasks(userId, { status: "done" })).map((t) => t.id)).toEqual([created.id]);
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
