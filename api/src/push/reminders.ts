import { deleteExpiredSessions } from "../auth/sessions";
import { addDays, dayIn, localDateTime } from "../data/dates";
import { prayerInstants } from "../data/prayers";
import { userOut } from "../data/rows";
import { RELATIVE_REMINDER_MIN, type Settings } from "../data/schemas";
import { isDeadToken, type PushEnvironment, type PushSender } from "./apns";

/**
 * Reminder pushes from the cron (every 5 minutes). The app schedules local notifications
 * for the next `LOCAL_WINDOW_MS` after every pull (`ReminderPlanner.windowDays` in
 * ZimamKit); the server pushes only what no device of the user can have scheduled:
 *
 *   a reminder firing at F for user U is pushed when no device of U has
 *   last_seen_at >= max(F - LOCAL_WINDOW_MS, changedAt)
 *
 * last_seen_at is the device's last pull. A device seen at T planned every reminder in
 * (T, T + 14 days] that it knew about, which is every change made before T. changedAt
 * is when the reminder (and, for prayer times, its task) last changed, so a reminder
 * added from the web or an assistant after the device's last pull is pushed too.
 *
 * A task's own time does not notify by itself: «عند الموعد» is a relative reminder at 0
 * (migrations/0018), so each person who has the task can keep or remove theirs.
 */

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;

/** The app's local window: `ReminderPlanner.windowDays` (14). Keep the two in step. */
export const LOCAL_WINDOW_MS = 14 * DAY;
/** The cron interval; each run reads at least what fired in (now - window, now]. */
export const CRON_WINDOW_MS = 5 * MINUTE;
/** How long sent-push records are kept for idempotency. */
const SENT_RETENTION_MS = 30 * DAY;
/** How far back a run picks up reminders an earlier run left (its cap, a failure, no run). */
const MAX_CATCH_UP_MS = 60 * MINUTE;
/**
 * The most notifications one run sends. With its claims (`CLAIM_CHUNK` a statement) and fixed
 * queries it stays well under a Worker invocation's 1,000 D1 queries and 1,000 subrequests,
 * which the attachments purge in the same run shares.
 */
export const MAX_SENDS_PER_RUN = 400;
/** Claims per INSERT: five bound parameters each, within D1's 100. */
const CLAIM_CHUNK = 18;
/** Notifications in flight at once: a Worker keeps six connections open at a time. */
const SEND_CONCURRENCY = 6;
/** The run's row in `cron_cursors` (migrations/0020). */
const CURSOR = "reminder_pushes";
/** APNs keeps trying an offline device this long after the reminder's time. */
const DELIVERY_GRACE_S = 24 * 60 * 60;
/**
 * The hour a reminder relative to an all-day task counts from: «قبل يوم» is 09:00 the day before.
 * `TaskTiming.allDayHour` in ZimamKit; keep the two in step.
 */
export const ALL_DAY_HOUR = "09:00";
/** The app's notification category, which carries the «إنجاز» and «تأجيل ساعة» buttons. */
const CATEGORY = "zimam.task";
const APP_NAME = "زمام";

type Prayer = "fajr" | "dhuhr" | "asr" | "maghrib" | "isha";

export interface DueReminder {
  userId: string;
  taskId: string;
  title: string;
  projectId: string | null;
  projectName: string | null;
  /** Unix ms, whole seconds. */
  fireAt: number;
  /** The planner's id, for logs and the sent record. */
  source: string;
}

interface DeviceRow {
  token: string;
  user_id: string;
  environment: PushEnvironment;
  bundle_id: string;
  last_seen_at: number;
}

interface Candidate extends DueReminder {
  changedAt: number;
}

export interface PushRunResult {
  /** Reminders that fired in the window and no device had scheduled. */
  due: number;
  /** Notifications APNs accepted. */
  sent: number;
  /** Device tokens removed because APNs no longer accepts them. */
  removedDevices: number;
  skipped?: "no_sender";
}

/** A device covers a reminder when it pulled after the reminder last changed, within the window before it fires. */
export function isCovered(devices: { last_seen_at: number }[], fireAt: number, changedAt: number): boolean {
  const since = Math.max(fireAt - LOCAL_WINDOW_MS, changedAt);
  return devices.some((d) => d.last_seen_at >= since);
}

/** Users who could need a push: at least one device, and none that surely covers the reminder. */
const NEEDS_PUSH = (user: string, changed: string) => `
  EXISTS (SELECT 1 FROM devices d WHERE d.user_id = ${user})
  AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.user_id = ${user} AND d.last_seen_at >= MAX(?3, ${changed}))`;

const HAS_LOCATION = `(CASE WHEN json_valid(u.settings) THEN json_extract(u.settings, '$.location') END) IS NOT NULL`;

/**
 * The reminder's user still sees its task: the inbox's owner, or a member of its project. Moving a
 * task or removing a member deletes the reminders of whoever loses it (src/data/mutations.ts,
 * src/data/membership.ts); this keeps a push from carrying a task's title to anyone else anyway.
 */
const SEES_TASK = `CASE WHEN t.project_id IS NULL THEN t.owner_id = r.user_id
  ELSE EXISTS (SELECT 1 FROM project_members m WHERE m.project_id = t.project_id AND m.user_id = r.user_id) END`;

interface RelativeRow {
  source: string;
  user_id: string;
  offset_minutes: number;
  changed_at: number;
  task_id: string;
  title: string;
  project_id: string | null;
  project_name: string | null;
  due_date: string | null;
  due_time: string | null;
  due_prayer: Prayer | null;
  due_prayer_offset: number;
  settings: string;
}

interface PrayerRow {
  source: string;
  user_id: string;
  prayer: Prayer;
  offset_minutes: number;
  changed_at: number;
  task_id: string;
  title: string;
  project_id: string | null;
  project_name: string | null;
  due_date: string | null;
  settings: string;
}

/**
 * Reminders that fired in (from, to] and that no device of their user can have scheduled.
 * Prayer-relative ones use the user's saved location and time zone; without a location
 * they are skipped (the app has the device's own location; the server has none).
 */
export async function dueReminders(db: D1Database, from: number, to: number): Promise<DueReminder[]> {
  // Any device seen at or after this, and after the change, covers every F <= to.
  const surelyCoveredSince = to - LOCAL_WINDOW_MS;
  const candidates: Candidate[] = [];

  // Time reminders fire at `at`, read as whole seconds. So does a location reminder with a time,
  // unless the place came first (`fired_at`): it fires once, at whichever comes first.
  const time = await db
    .prepare(
      `SELECT r.id AS reminder_id, r.user_id, unixepoch(r.at) * 1000 AS fire_at, r.updated_at AS changed_at,
              t.id AS task_id, t.title, t.project_id, p.name AS project_name
       FROM reminders r
       JOIN tasks t ON t.id = r.task_id
       LEFT JOIN projects p ON p.id = t.project_id
       WHERE (r.kind = 'time' OR (r.kind = 'location' AND r.at IS NOT NULL AND r.fired_at IS NULL))
         AND r.deleted_at IS NULL
         AND unixepoch(r.at) > ?1 AND unixepoch(r.at) <= ?2
         AND t.deleted_at IS NULL AND t.status <> 'done'
         AND ${SEES_TASK}
         AND ${NEEDS_PUSH("r.user_id", "r.updated_at")}`,
    )
    .bind(Math.floor(from / 1000), Math.floor(to / 1000), surelyCoveredSince)
    .all<{
      reminder_id: string;
      user_id: string;
      fire_at: number;
      changed_at: number;
      task_id: string;
      title: string;
      project_id: string | null;
      project_name: string | null;
    }>();
  for (const r of time.results) {
    candidates.push({
      userId: r.user_id,
      taskId: r.task_id,
      title: r.title,
      projectId: r.project_id,
      projectName: r.project_name,
      fireAt: r.fire_at,
      source: `reminder-${r.reminder_id}`,
      changedAt: r.changed_at,
    });
  }

  // Prayer-relative: the window can straddle midnight in any zone and an offset reaches
  // ±12 hours, so dated tasks within two UTC days of now are read and checked exactly.
  const utcToday = new Date(to).toISOString().slice(0, 10);
  const dayMin = addDays(utcToday, -2);
  const dayMax = addDays(utcToday, 2);

  const prayerReminders = await db
    .prepare(
      `SELECT 'reminder-' || r.id AS source, r.user_id, r.prayer, COALESCE(r.offset_minutes, 0) AS offset_minutes,
              MAX(r.updated_at, t.updated_at) AS changed_at, t.id AS task_id, t.title, t.project_id, t.due_date,
              p.name AS project_name, u.settings
       FROM reminders r
       JOIN tasks t ON t.id = r.task_id
       JOIN users u ON u.id = r.user_id
       LEFT JOIN projects p ON p.id = t.project_id
       WHERE r.kind = 'prayer' AND r.deleted_at IS NULL AND r.prayer IS NOT NULL
         AND t.deleted_at IS NULL AND t.status <> 'done'
         AND (t.due_date IS NULL OR t.due_date BETWEEN ?1 AND ?2)
         AND ${HAS_LOCATION}
         AND ${SEES_TASK}
         AND ${NEEDS_PUSH("r.user_id", "MAX(r.updated_at, t.updated_at)")}`,
    )
    .bind(dayMin, dayMax, surelyCoveredSince)
    .all<PrayerRow>();

  // Relative to the task's time: its clock time or its prayer on its day (09:00 for an all-day
  // task), or its prayer every day when it has no day. They come up to a week before it.
  const relativeReminders = await db
    .prepare(
      `SELECT 'reminder-' || r.id AS source, r.user_id, COALESCE(r.offset_minutes, 0) AS offset_minutes,
              MAX(r.updated_at, t.updated_at) AS changed_at, t.id AS task_id, t.title, t.project_id, t.due_date,
              t.due_time, t.due_prayer, COALESCE(t.due_prayer_offset, 0) AS due_prayer_offset,
              p.name AS project_name, u.settings
       FROM reminders r
       JOIN tasks t ON t.id = r.task_id
       JOIN users u ON u.id = r.user_id
       LEFT JOIN projects p ON p.id = t.project_id
       WHERE r.kind = 'relative' AND r.deleted_at IS NULL
         AND t.deleted_at IS NULL AND t.status <> 'done'
         AND (t.due_date BETWEEN ?1 AND ?4 OR (t.due_date IS NULL AND t.due_prayer IS NOT NULL))
         AND ${SEES_TASK}
         AND ${NEEDS_PUSH("r.user_id", "MAX(r.updated_at, t.updated_at)")}`,
    )
    .bind(dayMin, dayMax, surelyCoveredSince, addDays(dayMax, Math.ceil(-RELATIVE_REMINDER_MIN / (24 * 60))))
    .all<RelativeRow>();

  const times = new Map<string, ReturnType<typeof prayerInstants>>();
  const settingsOf = new Map<string, Settings>();
  const settingsFor = (row: { user_id: string; settings: string }) => {
    let settings = settingsOf.get(row.user_id);
    if (!settings) {
      settings = userOut({ settings: row.settings }).settings;
      settingsOf.set(row.user_id, settings);
    }
    return settings;
  };
  const prayerTime = (userId: string, day: string, settings: Settings, prayer: Prayer) => {
    const key = `${userId}|${day}`;
    if (!times.has(key)) times.set(key, prayerInstants(day, settings));
    return times.get(key)?.[prayer];
  };

  for (const row of prayerReminders.results) {
    const settings = settingsFor(row);
    if (!settings.location) continue;
    const today = dayIn(settings.timeZone, new Date(to));
    const days = row.due_date ? [row.due_date] : [addDays(today, -1), today, addDays(today, 1)];
    for (const day of days) {
      const instant = prayerTime(row.user_id, day, settings, row.prayer);
      if (!instant) continue;
      // Whole seconds, like time reminders (adhan already rounds to the minute).
      const fireAt = Math.floor((instant.getTime() + row.offset_minutes * MINUTE) / 1000) * 1000;
      if (fireAt <= from || fireAt > to) continue;
      candidates.push({
        userId: row.user_id,
        taskId: row.task_id,
        title: row.title,
        projectId: row.project_id,
        projectName: row.project_name,
        fireAt,
        source: `${row.source}@${day}`,
        changedAt: row.changed_at,
      });
    }
  }
  for (const row of relativeReminders.results) {
    const settings = settingsFor(row);
    if (row.due_prayer && !settings.location) continue;
    const today = dayIn(settings.timeZone, new Date(to));
    // Without a day the task repeats at its prayer; a reminder a day before today's falls on yesterday's.
    const ahead = Math.ceil(-row.offset_minutes / (24 * 60));
    const days = row.due_date
      ? [row.due_date]
      : Array.from({ length: ahead + 3 }, (_, i) => addDays(today, i - 1));
    for (const day of days) {
      let base: number | undefined;
      if (row.due_prayer) {
        base = prayerTime(row.user_id, day, settings, row.due_prayer)?.getTime();
        if (base !== undefined) base += row.due_prayer_offset * MINUTE;
      } else {
        base = Date.parse(localDateTime(day, row.due_time ?? ALL_DAY_HOUR, settings.timeZone));
      }
      if (base === undefined || Number.isNaN(base)) continue;
      const fireAt = Math.floor((base + row.offset_minutes * MINUTE) / 1000) * 1000;
      if (fireAt <= from || fireAt > to) continue;
      candidates.push({
        userId: row.user_id,
        taskId: row.task_id,
        title: row.title,
        projectId: row.project_id,
        projectName: row.project_name,
        fireAt,
        source: `${row.source}@${day}`,
        changedAt: row.changed_at,
      });
    }
  }
  if (candidates.length === 0) return [];

  // The exact rule, per fire time, against every device of the user.
  const devices = await devicesOf(db, [...new Set(candidates.map((c) => c.userId))]);
  return candidates
    .filter((c) => !isCovered(devices.get(c.userId) ?? [], c.fireAt, c.changedAt) && devices.has(c.userId))
    .sort((a, b) => a.fireAt - b.fireAt || a.source.localeCompare(b.source))
    .map(({ changedAt: _, ...due }) => due);
}

async function devicesOf(db: D1Database, userIds: string[]): Promise<Map<string, DeviceRow[]>> {
  const byUser = new Map<string, DeviceRow[]>();
  // D1 binds at most 100 parameters per statement.
  for (let i = 0; i < userIds.length; i += 90) {
    const chunk = userIds.slice(i, i + 90);
    const { results } = await db
      .prepare(
        `SELECT token, user_id, environment, bundle_id, last_seen_at FROM devices
         WHERE user_id IN (${chunk.map(() => "?").join(", ")})`,
      )
      .bind(...chunk)
      .all<DeviceRow>();
    for (const row of results) byUser.set(row.user_id, [...(byUser.get(row.user_id) ?? []), row]);
  }
  return byUser;
}

/** The alert: the project's name (or «زمام») as the title and the task's title as the body. */
export function reminderPayload(due: DueReminder): Record<string, unknown> {
  return {
    aps: {
      alert: { title: due.projectName ?? APP_NAME, body: due.title },
      sound: "default",
      category: CATEGORY,
      "thread-id": due.projectId ?? "inbox",
    },
    taskId: due.taskId,
  };
}

/**
 * The cron's work: deletes expired sessions (and with them their devices), then pushes the
 * reminders that fired since the last run and that no device scheduled. Each (user, task, minute)
 * is claimed in `reminder_pushes` before sending, so a reminder is pushed at most once even if a
 * window is read again.
 *
 * A run reads from where the previous one stopped (`cron_cursors`): the last 5 minutes, or further
 * back, up to an hour, after a run that hit its cap, failed or did not run. It sends at most
 * `MAX_SENDS_PER_RUN` notifications, claiming in batches and sending a few at a time, so it stays
 * within a Worker's limits on D1 queries and subrequests; what is left waits for the next run.
 */
export async function sendDueReminders(db: D1Database, sender: PushSender | null, now: number): Promise<PushRunResult> {
  await deleteExpiredSessions(db, now);
  if (!sender) {
    console.warn("push: APNS_KEY_ID or APNS_PRIVATE_KEY is not set; reminder pushes skipped");
    return { due: 0, sent: 0, removedDevices: 0, skipped: "no_sender" };
  }
  await db.prepare(`DELETE FROM reminder_pushes WHERE sent_at < ?`).bind(now - SENT_RETENTION_MS).run();

  const last = await db.prepare(`SELECT until_at FROM cron_cursors WHERE name = ?`).bind(CURSOR).first<{ until_at: number }>();
  const from = Math.max(now - MAX_CATCH_UP_MS, Math.min(last?.until_at ?? now, now - CRON_WINDOW_MS));
  const due = await dueReminders(db, from, now);
  const result: PushRunResult = { due: due.length, sent: 0, removedDevices: 0 };

  const devices = await devicesOf(db, [...new Set(due.map((d) => d.userId))]);
  const dead = new Set<string>();
  let budget = MAX_SENDS_PER_RUN;
  let next = 0;
  while (next < due.length) {
    // The next claims: no more than the notifications left could send, so nothing claimed goes
    // unsent (the run's first reminder always goes).
    const first = next;
    const chunk: DueReminder[] = [];
    let most = 0;
    for (; next < due.length && chunk.length < CLAIM_CHUNK; next++) {
      const cost = devices.get(due[next]!.userId)?.length ?? 0;
      if (most + cost > budget && !(chunk.length === 0 && budget === MAX_SENDS_PER_RUN)) break;
      most += cost;
      chunk.push(due[next]!);
    }
    if (chunk.length === 0) break;

    let claimed: Set<string>;
    try {
      claimed = await claim(db, chunk, now);
    } catch (err) {
      // Nothing in the chunk was claimed: the next run starts from it.
      console.error("push: claiming reminders failed:", (err as Error).message);
      next = first;
      break;
    }
    const pushes: { reminder: DueReminder; device: DeviceRow }[] = [];
    for (const reminder of chunk) {
      // One notification per claim: reminders of a task in the same minute share it, and one
      // claimed before (a window read again) costs nothing.
      if (!claimed.delete(claimKey(reminder.userId, reminder.taskId, Math.floor(reminder.fireAt / MINUTE)))) continue;
      const targets = devices.get(reminder.userId) ?? [];
      budget -= targets.length;
      for (const device of targets) pushes.push({ reminder, device });
    }
    await pool(pushes, SEND_CONCURRENCY, async ({ reminder, device }) => {
      if (dead.has(device.token)) return;
      const sent = await sender.send({
        token: device.token,
        environment: device.environment,
        topic: device.bundle_id,
        payload: reminderPayload(reminder),
        expiration: Math.floor(reminder.fireAt / 1000) + DELIVERY_GRACE_S,
      });
      if (sent.status === 200) {
        result.sent += 1;
      } else if (isDeadToken(sent)) {
        dead.add(device.token);
      } else {
        console.error(`push: APNs ${sent.status} ${sent.reason ?? ""} for ${reminder.source}`);
      }
    });
  }

  const tokens = [...dead];
  for (let i = 0; i < tokens.length; i += 90) {
    const chunk = tokens.slice(i, i + 90);
    await db.prepare(`DELETE FROM devices WHERE token IN (${chunk.map(() => "?").join(", ")})`).bind(...chunk).run();
  }
  result.removedDevices = tokens.length;

  // The next run starts at the first reminder this one left, or at its end.
  const until = next < due.length ? due[next]!.fireAt - 1 : now;
  await db
    .prepare(`INSERT INTO cron_cursors (name, until_at) VALUES (?1, ?2) ON CONFLICT (name) DO UPDATE SET until_at = excluded.until_at`)
    .bind(CURSOR, until)
    .run();
  return result;
}

const claimKey = (userId: string, taskId: string, fireMinute: number) => `${userId}|${taskId}|${fireMinute}`;

/** Claims a chunk of reminders in one statement; returns the keys claimed now, not before. */
async function claim(db: D1Database, chunk: DueReminder[], now: number): Promise<Set<string>> {
  const { results } = await db
    .prepare(
      `INSERT OR IGNORE INTO reminder_pushes (user_id, task_id, fire_minute, source, sent_at)
       VALUES ${chunk.map(() => "(?, ?, ?, ?, ?)").join(", ")}
       RETURNING user_id, task_id, fire_minute`,
    )
    .bind(...chunk.flatMap((r) => [r.userId, r.taskId, Math.floor(r.fireAt / MINUTE), r.source, now]))
    .all<{ user_id: string; task_id: string; fire_minute: number }>();
  return new Set(results.map((r) => claimKey(r.user_id, r.task_id, r.fire_minute)));
}

/** Runs `work` over `items`, `size` at a time. One that throws is logged; the rest go on. */
async function pool<T>(items: T[], size: number, work: (item: T) => Promise<void>) {
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const item = items[next++]!;
      try {
        await work(item);
      } catch (err) {
        console.error("push: send failed:", (err as Error).message);
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(size, items.length) }, worker));
}
