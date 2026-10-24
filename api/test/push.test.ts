import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { decodeProtectedHeader, exportPKCS8, generateKeyPair, jwtVerify } from "jose";
import { describe, expect, it } from "vitest";
import { sha256Hex } from "../src/auth/crypto";
import { prayerInstants } from "../src/data/prayers";
import { DEFAULT_SETTINGS } from "../src/data/schemas";
import worker from "../src/index";
import {
  ApnsSender,
  D1TokenStore,
  MemoryTokenStore,
  normalizePem,
  type PushMessage,
  type PushResult,
  type PushSender,
} from "../src/push/apns";
import { CRON_WINDOW_MS, isCovered, LOCAL_WINDOW_MS, MAX_SENDS_PER_RUN, sendDueReminders } from "../src/push/reminders";
import { addMember, call, pullAll, push as syncPush, signIn, uuid } from "./helpers";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** Records every message and answers with a per-token status (200 by default). */
class FakePush implements PushSender {
  sent: PushMessage[] = [];
  answers = new Map<string, PushResult>();
  async send(message: PushMessage): Promise<PushResult> {
    this.sent.push(message);
    return this.answers.get(message.token) ?? { status: 200 };
  }
  to(token: string) {
    return this.sent.filter((m) => m.token === token);
  }
}

const deviceToken = () => [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, "0")).join("");

const deviceBody = { platform: "ios", environment: "sandbox", bundleId: "app.zimam.ios" };

async function device(token: string) {
  return env.DB.prepare(`SELECT * FROM devices WHERE token = ?`).bind(token).first<Record<string, unknown>>();
}

async function setSeen(token: string, at: number) {
  await env.DB.prepare(`UPDATE devices SET last_seen_at = ? WHERE token = ?`).bind(at, token).run();
}

/** A signed-in user with one registered device, never pulled (so nothing is covered). */
async function userWithDevice(settings?: Record<string, unknown>, sub?: string) {
  const user = await signIn(sub);
  // The cron deletes expired sessions (180 days unused), and these tests run it in 2027.
  await env.DB.prepare(`UPDATE sessions SET expires_at = ? WHERE token_hash = ?`)
    .bind(Date.UTC(2100, 0, 1), await sha256Hex(user.token))
    .run();
  const apns = deviceToken();
  const res = await call("PUT", `/v1/devices/${apns}`, { token: user.token, body: deviceBody });
  expect(res.status).toBe(204);
  if (settings) {
    const patched = await call("PATCH", "/v1/me", { token: user.token, body: { settings } });
    expect(patched.status).toBe(200);
  }
  return { ...user, apns };
}

const iso = (ms: number) => new Date(ms).toISOString().replace(".000Z", "Z");

async function addTask(token: string, extra: Record<string, unknown> = {}, updatedAt = 1000) {
  const id = uuid();
  const [result] = await syncPush(token, [
    { op: "upsert", entity: "task", data: { id, title: "مراجعة العقد", updatedAt, ...extra } },
  ]);
  expect(result!.status).toBe("applied");
  return id;
}

async function addReminder(token: string, taskId: string, data: Record<string, unknown>, updatedAt = 1000) {
  const id = uuid();
  const [result] = await syncPush(token, [{ op: "upsert", entity: "reminder", data: { id, taskId, updatedAt, ...data } }]);
  expect(result!.status).toBe("applied");
  return id;
}

/** The end of the 5-minute cron window that contains `ms`. */
const windowEnd = (ms: number) => Math.ceil(ms / CRON_WINDOW_MS) * CRON_WINDOW_MS;

describe("Device registration", () => {
  it("registers a device for the signed-in session and validates input", async () => {
    const { token, userId } = await signIn();
    const apns = deviceToken();
    expect((await call("PUT", `/v1/devices/${apns}`, { body: deviceBody })).status).toBe(401);
    expect((await call("PUT", "/v1/devices/not-hex", { token, body: deviceBody })).status).toBe(400);
    expect((await call("PUT", `/v1/devices/${apns}`, { token, body: { ...deviceBody, platform: "android" } })).status).toBe(400);
    expect((await call("PUT", `/v1/devices/${apns}`, { token, body: { platform: "ios" } })).status).toBe(400);

    const res = await call("PUT", `/v1/devices/${apns.toUpperCase()}`, { token, body: deviceBody });
    expect(res.status).toBe(204);
    expect(await device(apns)).toMatchObject({
      user_id: userId,
      session_hash: await sha256Hex(token),
      platform: "ios",
      environment: "sandbox",
      bundle_id: "app.zimam.ios",
      last_seen_at: 0,
    });

    // Registering again is idempotent.
    expect((await call("PUT", `/v1/devices/${apns}`, { token, body: { ...deviceBody, environment: "production" } })).status).toBe(204);
    expect((await device(apns))!.environment).toBe("production");
  });

  it("replaces the session's older token on the same platform", async () => {
    const { token } = await signIn();
    const first = deviceToken();
    const second = deviceToken();
    const mac = deviceToken();
    await call("PUT", `/v1/devices/${first}`, { token, body: deviceBody });
    await call("PUT", `/v1/devices/${mac}`, { token, body: { ...deviceBody, platform: "macos" } });
    await call("PUT", `/v1/devices/${second}`, { token, body: deviceBody });
    expect(await device(first)).toBeNull();
    expect(await device(second)).not.toBeNull();
    expect(await device(mac)).not.toBeNull();
  });

  it("lets only the owner delete a device, and moves a token to the account that registers it", async () => {
    const a = await signIn();
    const b = await signIn();
    const apns = deviceToken();
    await call("PUT", `/v1/devices/${apns}`, { token: a.token, body: deviceBody });
    await setSeen(apns, 5000);

    expect((await call("DELETE", `/v1/devices/${apns}`, { token: b.token })).status).toBe(404);
    expect(await device(apns)).not.toBeNull();

    // The same install signs in to B: the token moves, and counts as unseen until B pulls.
    expect((await call("PUT", `/v1/devices/${apns}`, { token: b.token, body: deviceBody })).status).toBe(204);
    expect(await device(apns)).toMatchObject({ user_id: b.userId, session_hash: await sha256Hex(b.token), last_seen_at: 0 });
    expect((await call("DELETE", `/v1/devices/${apns}`, { token: a.token })).status).toBe(404);

    expect((await call("DELETE", `/v1/devices/${apns}`, { token: b.token })).status).toBe(204);
    expect(await device(apns)).toBeNull();
    expect((await call("DELETE", `/v1/devices/${apns}`, { token: b.token })).status).toBe(404);
  });

  it("marks the session's devices seen on each pull, and only them", async () => {
    const sub = `apple-${uuid()}`;
    const phone = await userWithDevice(undefined, sub);
    const ipad = await userWithDevice(undefined, sub);
    expect(ipad.userId).toBe(phone.userId);

    const before = Date.now();
    await pullAll(phone.token);
    expect((await device(phone.apns))!.last_seen_at as number).toBeGreaterThanOrEqual(before);
    expect((await device(ipad.apns))!.last_seen_at).toBe(0);

    // Re-registering from the same session keeps the last pull.
    const seen = (await device(phone.apns))!.last_seen_at;
    await call("PUT", `/v1/devices/${phone.apns}`, { token: phone.token, body: deviceBody });
    expect((await device(phone.apns))!.last_seen_at).toBe(seen);
  });

  it("removes the device when its session signs out", async () => {
    const { token, apns } = await userWithDevice();
    expect((await call("POST", "/v1/auth/logout", { token })).status).toBe(204);
    expect(await device(apns)).toBeNull();
  });
});

describe("Reminder pushes", () => {
  it("pushes a time reminder that fired in the window, once, with the task's title", async () => {
    const now = Date.UTC(2027, 0, 10, 6, 0, 0);
    const user = await userWithDevice();
    const inbox = await addTask(user.token, { title: "مراجعة العقد" });
    const projectId = uuid();
    await syncPush(user.token, [{ op: "upsert", entity: "project", data: { id: projectId, name: "العمل", updatedAt: 1000 } }]);
    const inProject = await addTask(user.token, { title: "إرسال التقرير", projectId });
    const done = await addTask(user.token, { title: "منجزة", status: "done" });

    await addReminder(user.token, inbox, { kind: "time", at: "2027-01-10T08:58:00+03:00" }); // now - 2 min
    await addReminder(user.token, inProject, { kind: "time", at: iso(now - 4 * MINUTE) });
    await addReminder(user.token, done, { kind: "time", at: iso(now - MINUTE) });
    await addReminder(user.token, inbox, { kind: "time", at: iso(now - 6 * MINUTE) }); // the previous run's
    const later = await addReminder(user.token, inbox, { kind: "time", at: iso(now + 3 * MINUTE) });
    const deleted = await addReminder(user.token, inProject, { kind: "time", at: iso(now - MINUTE) });
    await syncPush(user.token, [{ op: "delete", entity: "reminder", id: deleted, updatedAt: 2000 }]);

    // The previous run sent the one before this window.
    await sendDueReminders(env.DB, new FakePush(), now - CRON_WINDOW_MS);
    const fake = new FakePush();
    const run = await sendDueReminders(env.DB, fake, now);
    expect(run).toMatchObject({ due: 2, sent: 2 });
    const [first, second] = fake.to(user.apns);
    expect(fake.to(user.apns)).toHaveLength(2);
    expect(first).toMatchObject({
      environment: "sandbox",
      topic: "app.zimam.ios",
      expiration: Math.floor((now - 4 * MINUTE) / 1000) + 24 * 60 * 60,
      payload: {
        aps: { alert: { title: "العمل", body: "إرسال التقرير" }, sound: "default", category: "zimam.task", "thread-id": projectId },
        taskId: inProject,
      },
    });
    expect(second!.payload).toEqual({
      aps: { alert: { title: "زمام", body: "مراجعة العقد" }, sound: "default", category: "zimam.task", "thread-id": "inbox" },
      taskId: inbox,
    });

    // The same window again sends nothing.
    expect(await sendDueReminders(env.DB, fake, now)).toMatchObject({ sent: 0 });
    expect(fake.to(user.apns)).toHaveLength(2);

    // The next window sends the later one.
    expect(await sendDueReminders(env.DB, fake, now + CRON_WINDOW_MS)).toMatchObject({ due: 1, sent: 1 });
    expect(fake.to(user.apns)[2]!.payload.taskId).toBe(inbox);
    const record = await env.DB.prepare(`SELECT source FROM reminder_pushes WHERE user_id = ? AND task_id = ? ORDER BY fire_minute DESC`)
      .bind(user.userId, inbox)
      .first<{ source: string }>();
    expect(record!.source).toBe(`reminder-${later}`);
  });

  it("pushes a location reminder's time unless the place came first", async () => {
    const now = Date.UTC(2027, 1, 14, 6, 0, 0);
    const user = await userWithDevice();
    const waiting = await addTask(user.token, { title: "شراء الخبز" });
    const arrived = await addTask(user.token, { title: "سقي الزرع" });
    const place = { latitude: 24.7136, longitude: 46.6753, radius: 200, name: "البيت", trigger: "arrive" };
    await addReminder(user.token, waiting, { kind: "location", location: place, at: iso(now - 2 * MINUTE) });
    await addReminder(user.token, arrived, { kind: "location", location: place, at: iso(now - 2 * MINUTE), firedAt: now - HOUR });
    // A place alone is never pushed: only the device knows where it is.
    await addReminder(user.token, arrived, { kind: "location", location: place });

    const fake = new FakePush();
    expect(await sendDueReminders(env.DB, fake, now)).toMatchObject({ due: 1, sent: 1 });
    expect(fake.to(user.apns)[0]!.payload.taskId).toBe(waiting);
  });

  it("leaves to the device what it scheduled locally", async () => {
    const now = Date.UTC(2027, 1, 3, 9, 0, 0);
    const fireAt = now - MINUTE;
    const setup = async (seenAt: number, reminderUpdatedAt = 1000, sub?: string) => {
      const user = await userWithDevice(undefined, sub);
      const task = await addTask(user.token);
      await addReminder(user.token, task, { kind: "time", at: iso(fireAt) }, reminderUpdatedAt);
      await setSeen(user.apns, seenAt);
      return user;
    };
    // Pulled 13 days before: the reminder was inside its 14-day window.
    const active = await setup(fireAt - 13 * DAY);
    // Exactly at the window's edge still counts.
    const edge = await setup(fireAt - LOCAL_WINDOW_MS);
    // Pulled 15 days before: beyond its window.
    const dormant = await setup(fireAt - 15 * DAY);
    // Pulled yesterday, but the reminder was added (from the web) after that pull.
    const stale = await setup(fireAt - DAY, fireAt - 12 * HOUR);
    // A second device that pulled recently covers the user.
    const sub = `apple-${uuid()}`;
    const twoDevices = await setup(fireAt - 30 * DAY, 1000, sub);
    const ipad = await userWithDevice(undefined, sub);
    await setSeen(ipad.apns, fireAt - DAY);

    const fake = new FakePush();
    await sendDueReminders(env.DB, fake, now);
    expect(fake.to(active.apns)).toHaveLength(0);
    expect(fake.to(edge.apns)).toHaveLength(0);
    expect(fake.to(dormant.apns)).toHaveLength(1);
    expect(fake.to(stale.apns)).toHaveLength(1);
    expect(fake.to(twoDevices.apns)).toHaveLength(0);
    expect(fake.to(ipad.apns)).toHaveLength(0);
  });

  it("applies the rule per fire time", () => {
    const fireAt = 100 * DAY;
    expect(isCovered([], fireAt, 0)).toBe(false);
    expect(isCovered([{ last_seen_at: fireAt - LOCAL_WINDOW_MS }], fireAt, 0)).toBe(true);
    expect(isCovered([{ last_seen_at: fireAt - LOCAL_WINDOW_MS - 1 }], fireAt, 0)).toBe(false);
    expect(isCovered([{ last_seen_at: fireAt - DAY }], fireAt, fireAt - HOUR)).toBe(false);
    expect(isCovered([{ last_seen_at: 0 }, { last_seen_at: fireAt - DAY }], fireAt, fireAt - 2 * DAY)).toBe(true);
  });

  it("puts Hanafi Asr later than the majority's", () => {
    const settings = { ...DEFAULT_SETTINGS, location: { latitude: 24.7, longitude: 46.7 } };
    const shafi = prayerInstants("2027-03-20", settings)!;
    const hanafi = prayerInstants("2027-03-20", { ...settings, asrMadhab: "hanafi" })!;
    expect(hanafi.asr.getTime()).toBeGreaterThan(shafi.asr.getTime() + 30 * MINUTE);
    expect(hanafi.dhuhr.getTime()).toBe(shafi.dhuhr.getTime());
  });

  it("times prayer reminders from the user's location and time zone", async () => {
    const riyadh = { latitude: 24.7, longitude: 46.7 };
    const day = "2027-03-20";
    const settings = { ...DEFAULT_SETTINGS, timeZone: "Asia/Riyadh", location: riyadh };
    const asr = prayerInstants(day, settings)!.asr.getTime() + 20 * MINUTE;
    const maghrib = prayerInstants(day, settings)!.maghrib.getTime() - 10 * MINUTE;

    const user = await userWithDevice({ timeZone: "Asia/Riyadh", location: riyadh });
    const noLocation = await userWithDevice({ timeZone: "Asia/Riyadh" });
    const dated = await addTask(user.token, { title: "مراجعة العقد", dueDate: day });
    const reminder = await addReminder(user.token, dated, { kind: "prayer", prayer: "asr", offsetMinutes: 20 });
    // Anchored to Maghrib with no due day: every day, with «عند الموعد».
    const daily = await addTask(user.token, { title: "ورد المساء", duePrayer: "maghrib", duePrayerOffset: -10 });
    await addReminder(user.token, daily, { kind: "relative", offsetMinutes: 0 });
    const elsewhere = await addTask(noLocation.token, { dueDate: day });
    await addReminder(noLocation.token, elsewhere, { kind: "prayer", prayer: "asr", offsetMinutes: 20 });

    const fake = new FakePush();
    await sendDueReminders(env.DB, fake, windowEnd(asr) - CRON_WINDOW_MS);
    expect(fake.to(user.apns)).toHaveLength(0);
    await sendDueReminders(env.DB, fake, windowEnd(asr));
    expect(fake.to(user.apns).map((m) => m.payload.taskId)).toEqual([dated]);
    expect(fake.to(noLocation.apns)).toHaveLength(0);
    const sent = await env.DB.prepare(`SELECT source, fire_minute FROM reminder_pushes WHERE user_id = ? AND task_id = ?`)
      .bind(user.userId, dated)
      .first<{ source: string; fire_minute: number }>();
    expect(sent).toEqual({ source: `reminder-${reminder}@${day}`, fire_minute: Math.floor(asr / MINUTE) });

    await sendDueReminders(env.DB, fake, windowEnd(maghrib));
    expect(fake.to(user.apns).map((m) => m.payload.taskId)).toEqual([dated, daily]);

    // The next day's Maghrib, for the daily task.
    const nextDay = "2027-03-21";
    const nextMaghrib = prayerInstants(nextDay, settings)!.maghrib.getTime() - 10 * MINUTE;
    await sendDueReminders(env.DB, fake, windowEnd(nextMaghrib));
    expect(fake.to(user.apns).map((m) => m.payload.taskId)).toEqual([dated, daily, daily]);
  });

  it("notifies each member of a shared project who keeps «عند الموعد» on a prayer-anchored task", async () => {
    const mecca = { latitude: 21.4, longitude: 39.8 };
    const day = "2027-04-11";
    const settings = { ...DEFAULT_SETTINGS, timeZone: "Asia/Riyadh", location: mecca };
    const fajr = prayerInstants(day, settings)!.fajr.getTime();

    const owner = await userWithDevice({ timeZone: "Asia/Riyadh", location: mecca });
    const member = await userWithDevice({ timeZone: "Asia/Riyadh", location: mecca });
    const projectId = uuid();
    await syncPush(owner.token, [{ op: "upsert", entity: "project", data: { id: projectId, name: "البيت", updatedAt: 1000 } }]);
    await addMember(projectId, member.userId, "editor");
    const task = await addTask(owner.token, { title: "سقي الزرع", projectId, dueDate: day, duePrayer: "fajr" });
    await addReminder(member.token, task, { kind: "relative", offsetMinutes: 0 });
    // The owner's prayer reminder at the same minute as their «عند الموعد» does not double it.
    await addReminder(owner.token, task, { kind: "relative", offsetMinutes: 0 });
    await addReminder(owner.token, task, { kind: "prayer", prayer: "fajr", offsetMinutes: 0 });
    // A task's time alone notifies no one: a third member who removed «عند الموعد» gets nothing.
    const third = await userWithDevice({ timeZone: "Asia/Riyadh", location: mecca });
    await addMember(projectId, third.userId, "editor");

    const fake = new FakePush();
    await sendDueReminders(env.DB, fake, windowEnd(fajr));
    expect(fake.to(owner.apns)).toHaveLength(1);
    expect(fake.to(member.apns)).toHaveLength(1);
    expect(fake.to(third.apns)).toHaveLength(0);
    expect(fake.to(member.apns)[0]!.payload).toMatchObject({
      aps: { alert: { title: "البيت", body: "سقي الزرع" }, "thread-id": projectId },
      taskId: task,
    });
  });

  it("times relative reminders from a clock time, an all-day task's morning, and a prayer", async () => {
    const riyadh = { latitude: 24.7, longitude: 46.7 };
    const day = "2027-05-12";
    const settings = { ...DEFAULT_SETTINGS, timeZone: "Asia/Riyadh", location: riyadh };
    const user = await userWithDevice({ timeZone: "Asia/Riyadh", location: riyadh });

    // 15:00 in Riyadh is 12:00 UTC; «قبل ١٥ د» fires at 11:45 UTC.
    const meeting = await addTask(user.token, { title: "اجتماع", dueDate: day, dueTime: "15:00" });
    const before = await addReminder(user.token, meeting, { kind: "relative", offsetMinutes: -15 });
    // All day: «قبل يوم» is 09:00 the day before in Riyadh, 06:00 UTC.
    const report = await addTask(user.token, { title: "تسليم التقرير", dueDate: day });
    await addReminder(user.token, report, { kind: "relative", offsetMinutes: -24 * 60 });
    // A prayer a week ahead: «قبل ساعة» from that day's Asr.
    const later = "2027-05-19";
    const visit = await addTask(user.token, { title: "زيارة", dueDate: later, duePrayer: "asr", duePrayerOffset: -10 });
    await addReminder(user.token, visit, { kind: "relative", offsetMinutes: -60 });

    const fake = new FakePush();
    await sendDueReminders(env.DB, fake, Date.parse("2027-05-11T06:00:00Z"));
    expect(fake.to(user.apns).map((m) => m.payload.taskId)).toEqual([report]);
    await sendDueReminders(env.DB, fake, Date.parse("2027-05-12T11:45:00Z"));
    expect(fake.to(user.apns).map((m) => m.payload.taskId)).toEqual([report, meeting]);
    const sent = await env.DB.prepare(`SELECT source FROM reminder_pushes WHERE user_id = ? AND task_id = ?`)
      .bind(user.userId, meeting)
      .first<{ source: string }>();
    expect(sent?.source).toBe(`reminder-${before}@${day}`);

    const asr = prayerInstants(later, settings)!.asr.getTime() - 70 * MINUTE;
    await sendDueReminders(env.DB, fake, windowEnd(asr) - CRON_WINDOW_MS);
    expect(fake.to(user.apns)).toHaveLength(2);
    await sendDueReminders(env.DB, fake, windowEnd(asr));
    expect(fake.to(user.apns).map((m) => m.payload.taskId)).toEqual([report, meeting, visit]);
  });

  it("pushes nothing to someone who no longer sees the task", async () => {
    const now = Date.UTC(2027, 8, 1, 12, 0, 0);
    const owner = await userWithDevice();
    const member = await userWithDevice();
    const projectId = uuid();
    await syncPush(owner.token, [{ op: "upsert", entity: "project", data: { id: projectId, name: "البيت", updatedAt: 1000 } }]);
    await addMember(projectId, member.userId, "editor");
    const task = await addTask(owner.token, { title: "سقي الزرع", projectId });
    await addReminder(member.token, task, { kind: "time", at: iso(now - MINUTE) });
    await addReminder(owner.token, task, { kind: "time", at: iso(now - MINUTE) });
    // Out of the project without the Mutator's cleanup, as moved tasks once left reminders behind.
    await env.DB.prepare(`DELETE FROM project_members WHERE project_id = ? AND user_id = ?`).bind(projectId, member.userId).run();

    const fake = new FakePush();
    await sendDueReminders(env.DB, fake, now);
    expect(fake.to(owner.apns)).toHaveLength(1);
    expect(fake.to(member.apns)).toHaveLength(0);
  });

  it("deletes expired sessions with their devices before sending", async () => {
    const now = Date.UTC(2027, 8, 2, 12, 0, 0);
    const user = await userWithDevice();
    const task = await addTask(user.token);
    await addReminder(user.token, task, { kind: "time", at: iso(now - MINUTE) });
    // Unused for 180 days: signed out, the install can no longer unregister itself.
    const hash = await sha256Hex(user.token);
    await env.DB.prepare(`UPDATE sessions SET expires_at = ? WHERE token_hash = ?`).bind(now - DAY, hash).run();

    const fake = new FakePush();
    expect(await sendDueReminders(env.DB, fake, now)).toMatchObject({ due: 0, sent: 0 });
    expect(fake.sent).toHaveLength(0);
    expect(await device(user.apns)).toBeNull();
    expect(await env.DB.prepare(`SELECT 1 FROM sessions WHERE token_hash = ?`).bind(hash).first()).toBeNull();
  });

  it("sends at most a run's share and leaves the rest to the next run", async () => {
    const now = Date.UTC(2027, 8, 3, 12, 0, 0);
    const user = await userWithDevice();
    // More reminders in one window than a run sends, each on its own task.
    const extra = 25;
    const rows = [];
    for (let i = 0; i < MAX_SENDS_PER_RUN + extra; i++) {
      const task = uuid();
      rows.push(
        env.DB.prepare(`INSERT INTO tasks (id, owner_id, title, created_at, updated_at) VALUES (?, ?, ?, 1000, 1000)`).bind(
          task,
          user.userId,
          `مهمة ${i}`,
        ),
        env.DB.prepare(
          `INSERT INTO reminders (id, user_id, task_id, kind, at, created_at, updated_at) VALUES (?, ?, ?, 'time', ?, 1000, 1000)`,
        ).bind(uuid(), user.userId, task, iso(now - 4 * MINUTE + (i % 180) * 1000)),
      );
    }
    await env.DB.batch(rows);

    const fake = new FakePush();
    expect(await sendDueReminders(env.DB, fake, now)).toMatchObject({ due: MAX_SENDS_PER_RUN + extra, sent: MAX_SENDS_PER_RUN });
    // The next run starts where this one stopped, before its own five minutes.
    expect(await sendDueReminders(env.DB, fake, now + CRON_WINDOW_MS)).toMatchObject({ sent: extra });
    expect(new Set(fake.to(user.apns).map((m) => m.payload.taskId)).size).toBe(MAX_SENDS_PER_RUN + extra);
    expect(await sendDueReminders(env.DB, fake, now + 2 * CRON_WINDOW_MS)).toMatchObject({ due: 0, sent: 0 });
  });

  it("sends what a run that did not happen would have", async () => {
    const now = Date.UTC(2027, 8, 4, 12, 0, 0);
    const user = await userWithDevice();
    const task = await addTask(user.token);
    await sendDueReminders(env.DB, new FakePush(), now);
    await addReminder(user.token, task, { kind: "time", at: iso(now + 7 * MINUTE) });

    // The run at now + 10 minutes was missed; the next one covers its window too.
    const fake = new FakePush();
    expect(await sendDueReminders(env.DB, fake, now + 15 * MINUTE)).toMatchObject({ due: 1, sent: 1 });
    expect(fake.to(user.apns)[0]!.payload.taskId).toBe(task);
  });

  it("removes devices APNs no longer accepts", async () => {
    const now = Date.UTC(2027, 5, 1, 12, 0, 0);
    const sub = `apple-${uuid()}`;
    const gone = await userWithDevice(undefined, sub);
    const bad = await userWithDevice(undefined, sub);
    const flaky = await userWithDevice(undefined, sub);
    const task = await addTask(gone.token);
    await addReminder(gone.token, task, { kind: "time", at: iso(now - MINUTE) });

    const fake = new FakePush();
    fake.answers.set(gone.apns, { status: 410, reason: "Unregistered" });
    fake.answers.set(bad.apns, { status: 400, reason: "BadDeviceToken" });
    fake.answers.set(flaky.apns, { status: 503, reason: "ServiceUnavailable" });
    const run = await sendDueReminders(env.DB, fake, now);
    expect(run).toMatchObject({ due: 1, sent: 0, removedDevices: 2 });
    expect(fake.sent).toHaveLength(3);
    expect(await device(gone.apns)).toBeNull();
    expect(await device(bad.apns)).toBeNull();
    expect(await device(flaky.apns)).not.toBeNull();
  });

  it("skips without APNs secrets and sends later once they are set", async () => {
    const now = Date.UTC(2027, 6, 1, 12, 0, 0);
    const user = await userWithDevice();
    const task = await addTask(user.token);
    await addReminder(user.token, task, { kind: "time", at: iso(now - MINUTE) });
    expect(await sendDueReminders(env.DB, null, now)).toMatchObject({ skipped: "no_sender", sent: 0 });
    const fake = new FakePush();
    expect(await sendDueReminders(env.DB, fake, now)).toMatchObject({ sent: 1 });
  });

  it("runs from the cron trigger", async () => {
    const controller = createScheduledController({ scheduledTime: Date.UTC(2027, 7, 1, 12, 0, 0), cron: "*/5 * * * *" });
    const ctx = createExecutionContext();
    await worker.scheduled(controller, env, ctx);
    await waitOnExecutionContext(ctx);
  });
});

const apnsKey = await generateKeyPair("ES256", { extractable: true });
const publicKey = apnsKey.publicKey;
const pem = await exportPKCS8(apnsKey.privateKey);

describe("APNs sender", () => {

  function fakeApns(statuses: { status: number; reason?: string }[] = []) {
    const requests: { url: string; headers: Headers; body: string }[] = [];
    const doFetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push({ url: String(input), headers: new Headers(init?.headers), body: String(init?.body) });
      const next = statuses.shift() ?? { status: 200 };
      return next.status === 200
        ? new Response(null, { status: 200 })
        : new Response(JSON.stringify({ reason: next.reason }), { status: next.status });
    }) as typeof fetch;
    return { requests, doFetch };
  }

  const message = (environment: "sandbox" | "production" = "production"): PushMessage => ({
    token: "ab".repeat(32),
    environment,
    topic: "app.zimam.ios",
    payload: { aps: { alert: { title: "زمام", body: "مهمة" } }, taskId: "t" },
    expiration: 123,
  });

  it("signs an ES256 provider token and reuses it for 50 minutes", async () => {
    let clock = Date.UTC(2027, 0, 1, 10, 0, 0);
    const { requests, doFetch } = fakeApns();
    const store = new MemoryTokenStore();
    const options = { teamId: "72V86SZ2XC", keyId: "KEY1234567", privateKey: pem, store, fetch: doFetch, now: () => clock };
    const sender = new ApnsSender(options);

    expect(await sender.send(message())).toEqual({ status: 200 });
    const first = requests[0]!;
    expect(first.url).toBe(`https://api.push.apple.com/3/device/${"ab".repeat(32)}`);
    expect(first.headers.get("apns-push-type")).toBe("alert");
    expect(first.headers.get("apns-topic")).toBe("app.zimam.ios");
    expect(first.headers.get("apns-expiration")).toBe("123");
    expect(JSON.parse(first.body)).toEqual(message().payload);
    const jwt = first.headers.get("authorization")!.replace(/^bearer /, "");
    expect(decodeProtectedHeader(jwt)).toEqual({ alg: "ES256", kid: "KEY1234567" });
    const { payload } = await jwtVerify(jwt, publicKey, { issuer: "72V86SZ2XC", currentDate: new Date(clock) });
    expect(payload.iat).toBe(clock / 1000);

    clock += 49 * MINUTE;
    await sender.send(message("sandbox"));
    expect(requests[1]!.url.startsWith("https://api.sandbox.push.apple.com/3/device/")).toBe(true);
    expect(requests[1]!.headers.get("authorization")).toBe(first.headers.get("authorization"));

    // Another isolate (a new sender on the same store) reuses it too.
    await new ApnsSender(options).send(message());
    expect(requests[2]!.headers.get("authorization")).toBe(first.headers.get("authorization"));

    clock += 2 * MINUTE;
    await sender.send(message());
    const renewed = requests[3]!.headers.get("authorization")!;
    expect(renewed).not.toBe(first.headers.get("authorization"));
    expect((await jwtVerify(renewed.replace(/^bearer /, ""), publicKey, { currentDate: new Date(clock) })).payload.iat).toBe(
      clock / 1000,
    );
  });

  it("keeps the provider token in D1 across isolates", async () => {
    const clock = Date.UTC(2027, 0, 2, 10, 0, 0);
    const { requests, doFetch } = fakeApns();
    const options = { teamId: "72V86SZ2XC", keyId: `KEY${uuid().slice(0, 7)}`, privateKey: pem, fetch: doFetch, now: () => clock };
    await new ApnsSender({ ...options, store: new D1TokenStore(env.DB) }).send(message());
    D1TokenStore.clearMemory();
    await new ApnsSender({ ...options, store: new D1TokenStore(env.DB) }).send(message());
    expect(requests[1]!.headers.get("authorization")).toBe(requests[0]!.headers.get("authorization"));
  });

  it("signs a new token once when APNs says it expired, and reports failures", async () => {
    let clock = Date.UTC(2027, 0, 3, 10, 0, 0);
    const { requests, doFetch } = fakeApns([{ status: 403, reason: "ExpiredProviderToken" }, { status: 200 }, { status: 410, reason: "Unregistered" }]);
    const sender = new ApnsSender({
      teamId: "72V86SZ2XC",
      keyId: "KEY7654321",
      // As pasted on one line, with escaped newlines.
      privateKey: pem.replace(/\n/g, "\\n"),
      store: new MemoryTokenStore(),
      fetch: doFetch,
      now: () => clock,
    });
    await sender.providerToken();
    clock += 1000;
    expect(await sender.send(message())).toEqual({ status: 200 });
    expect(requests).toHaveLength(2);
    expect(requests[1]!.headers.get("authorization")).not.toBe(requests[0]!.headers.get("authorization"));
    expect(await sender.send(message())).toEqual({ status: 410, reason: "Unregistered" });
  });

  it("accepts the key as a bare base64 body", () => {
    const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
    expect(normalizePem(body).replace(/\s+/g, "")).toBe(pem.replace(/\s+/g, ""));
  });
});
