// A task's reminders on the web (TaskRemindersSection.swift): most count from the task's own time
// («عند الموعد», «قبل ١٥ د», «قبل يوم»), the rest are at a time or a prayer of their own. Reminders
// arrive on the person's devices (the server's push); place reminders are added in the app.
// Pure functions; tested in test/reminders.test.mjs.
import { arabicNumber } from "./numbers.js";
import { prayerPhrase } from "./prayer.js";

/** The offsets offered, in minutes before the task's time (RelativeReminderPhrase.presets). */
export const RELATIVE_PRESETS = [0, -5, -15, -30, -60, -1440];

/** «عند الموعد», «قبل ١٥ د», «قبل ساعة», «قبل ساعتين», «قبل يوم», «قبل يومين», «قبل ٣ أيام». */
export function relativeText(offsetMinutes) {
  const offset = Math.trunc(offsetMinutes ?? 0);
  if (offset === 0) return "عند الموعد";
  const m = Math.abs(offset);
  let duration;
  if (m % 1440 === 0) {
    const days = m / 1440;
    duration = days === 1 ? "يوم" : days === 2 ? "يومين" : `${arabicNumber(days)} أيام`;
  } else if (m % 60 === 0) {
    const hours = m / 60;
    duration = hours === 1 ? "ساعة" : hours === 2 ? "ساعتين" : `${arabicNumber(hours)} س`;
  } else {
    duration = `${arabicNumber(m)} د`;
  }
  return `${offset < 0 ? "قبل" : "بعد"} ${duration}`;
}

/** Whether reminders can count from the task: it has a day or a prayer. */
export const hasTaskTime = (task) => !!(task.dueDate || task.duePrayer);

/** An all-day task counts from the morning of its day, so only that and the day before. */
export function presetsFor(task, reminders) {
  const taken = new Set(reminders.filter((r) => r.kind === "relative").map((r) => r.offsetMinutes ?? 0));
  const allDay = !task.dueTime && !task.duePrayer;
  return (allDay ? [0, -1440] : RELATIVE_PRESETS).filter((o) => !taken.has(o));
}

/** The relative ones first, soonest first; then the rest in the order they were added. */
export function sortReminders(reminders) {
  const relative = reminders.filter((r) => r.kind === "relative").sort((a, b) => (a.offsetMinutes ?? 0) - (b.offsetMinutes ?? 0));
  return [...relative, ...reminders.filter((r) => r.kind !== "relative")];
}

/** What a reminder's row says: { kind: "relative" | "time" | "prayer" | "location", text }. */
export function reminderLabel(reminder, { formatTime } = {}) {
  switch (reminder.kind) {
    case "relative":
      return { kind: "relative", text: relativeText(reminder.offsetMinutes) };
    case "prayer":
      return { kind: "prayer", text: prayerPhrase(reminder.prayer, reminder.offsetMinutes) ?? "عند صلاة" };
    case "time":
      return { kind: "time", text: formatTime ? formatTime(reminder.at) : reminder.at };
    default: {
      const where = reminder.location?.name || "مكان";
      return { kind: "location", text: `${reminder.location?.trigger === "leave" ? "عند مغادرة" : "عند الوصول إلى"} ${where}` };
    }
  }
}

/** "2026-10-20T15:30" (from <input type="datetime-local">) as the API's ISO time with the viewer's offset. */
export function localToIso(local, offsetMinutes = -new Date(`${local}:00`).getTimezoneOffset()) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(local ?? "")) return null;
  const sign = offsetMinutes < 0 ? "-" : "+";
  const abs = Math.abs(offsetMinutes);
  const pad = (n) => String(n).padStart(2, "0");
  return `${local}:00${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

/** A reminder record ready for POST /v1/sync. */
export function newReminder(taskId, fields, now = Date.now()) {
  return { id: crypto.randomUUID(), taskId, at: null, prayer: null, offsetMinutes: null, location: null, updatedAt: now, ...fields };
}
