import { addDays } from "../../data/dates";
import { isTimeZone, zonedDateTime } from "../dates";
import { addNote, fitName, fitTask, type ImportBundle, type ImportedProject, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { zimamRule } from "../recurrence";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { htmlToText, MAX_PAGES, type Provider, providerGet } from "./provider-http";

export const CALENDAR_API = "https://www.googleapis.com/calendar/v3";
/** The window read from each calendar: from this many days ago... */
export const CALENDAR_PAST_DAYS = 30;
/** ...to this many days ahead. */
export const CALENDAR_FUTURE_DAYS = 365;

interface CalendarEntry {
  id: string;
  summary?: string;
  /** The name the user gave a calendar shared with them. */
  summaryOverride?: string;
  primary?: boolean;
  /** Ticked in Google Calendar's list: the calendars the user chose to see. */
  selected?: boolean;
  hidden?: boolean;
  deleted?: boolean;
}

interface EventTime {
  /** All-day: "2026-10-20". */
  date?: string;
  /** Timed: "2026-10-20T09:00:00+03:00". */
  dateTime?: string;
  timeZone?: string;
}

export interface GoogleEvent {
  id: string;
  status?: string;
  summary?: string;
  description?: string;
  location?: string;
  start?: EventTime;
  /** Exclusive for all-day events: a one-day event ends the next day. */
  end?: EventTime;
  /** A series: ["RRULE:FREQ=WEEKLY;BYDAY=MO", "EXDATE;...", ...]. */
  recurrence?: string[];
  /** An occurrence of a series, or an exception to one. */
  recurringEventId?: string;
  originalStartTime?: EventTime;
  eventType?: string;
}

export interface GoogleCalendarData {
  /** The user's local day when importing: a series is due on its first occurrence on or after it. */
  today: string;
  calendars: {
    calendar: CalendarEntry;
    /** Read with `singleEvents=true`: single events and every occurrence of a series in the window. */
    events: GoogleEvent[];
    /** Read with `singleEvents=false`: series as their rule, and their exceptions (moved or cancelled occurrences). */
    series: GoogleEvent[];
  }[];
}

/** Calendars Google makes, not the user: public holidays, contacts' birthdays. */
const isGoogleMade = (c: CalendarEntry) => /@group\.v\.calendar\.google\.com$/i.test(c.id);

/** The calendars imported: the primary one and those ticked in Google Calendar, without Google's own. */
export function isChosenCalendar(c: CalendarEntry): boolean {
  return !c.deleted && !c.hidden && (c.primary === true || c.selected === true) && !isGoogleMade(c);
}

/** Not tasks: Google's working-location markers and birthdays. */
const SKIPPED_TYPES = new Set(["workingLocation", "birthday"]);

interface Due {
  dueDate: string;
  dueTime: string | null;
  startDate: string | null;
}

/** Where an event falls in the user's zone. Multi-day all-day events span from their first to their last day. */
function dueOf(e: GoogleEvent, timeZone: string): Due | null {
  if (e.start?.date) {
    const last = e.end?.date ? addDays(e.end.date, -1) : e.start.date;
    return last > e.start.date
      ? { dueDate: last, dueTime: null, startDate: e.start.date }
      : { dueDate: e.start.date, dueTime: null, startDate: null };
  }
  const ms = e.start?.dateTime ? Date.parse(e.start.dateTime) : Number.NaN;
  if (!Number.isFinite(ms)) return null;
  const { date, time } = zonedDateTime(ms, timeZone);
  return { dueDate: date, dueTime: time, startDate: null };
}

/** Sorting key: the start as written ("2026-10-20" sorts before "2026-10-20T09:00"). */
const startKey = (e: GoogleEvent) => e.start?.dateTime ?? e.start?.date ?? "";

function notesOf(e: GoogleEvent): string | null {
  let notes = e.description ? htmlToText(e.description) || null : null;
  if (e.location?.trim()) notes = addNote(notes, `المكان: ${e.location.trim()}`);
  return notes;
}

/**
 * A series as one repeating task, when Zimam repeats it on the same days: one RRULE and nothing
 * else (no EXDATE or RDATE), no moved or cancelled occurrence, an occurrence still to come, the
 * same day in the event's zone and the user's, and a rule in Zimam's subset. COUNT is what is
 * left from the next occurrence, so only when the whole series is in the window.
 */
function seriesRule(master: GoogleEvent, occurrences: GoogleEvent[], hasExceptions: boolean, today: string, timeZone: string) {
  const lines = master.recurrence ?? [];
  const rules = lines.filter((l) => /^RRULE:/i.test(l));
  if (rules.length !== 1 || lines.length !== 1 || hasExceptions) return null;
  const index = occurrences.findIndex((o) => (dueOf(o, timeZone)?.dueDate ?? "") >= today);
  const next = occurrences[index];
  if (!next) return null;
  const due = dueOf(next, timeZone);
  if (!due || due.startDate) return null;
  if (next.start?.dateTime) {
    const zone = isTimeZone(next.start.timeZone ?? master.start?.timeZone) ? (next.start.timeZone ?? master.start!.timeZone!) : timeZone;
    if (zonedDateTime(Date.parse(next.start.dateTime), zone).date !== due.dueDate) return null;
  }
  let rule = zimamRule(rules[0]!, due.dueDate);
  if (!rule) return null;
  const count = rule.match(/COUNT=(\d+)/);
  if (count) {
    if (Number(count[1]) !== occurrences.length) return null;
    rule = rule.replace(/COUNT=\d+/, `COUNT=${occurrences.length - index}`);
  }
  return { rule, next, due };
}

/**
 * Google Calendar events as tasks: a project per chosen calendar (its calendar view), each
 * event a task due when it starts (in the user's zone), the description and place in the
 * notes. A series is one repeating task when Zimam can repeat it (see `seriesRule`), and
 * otherwise each of its occurrences in the window is a task of its own. Events are not marked
 * done: Google has no such state. Cancelled events, working-location markers and birthdays
 * are skipped.
 */
export function mapGoogleCalendar(data: GoogleCalendarData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const tasks: ImportedTask[] = [];
  const zone = ctx.timeZone;
  let expanded = 0;

  const chosen = data.calendars.filter(({ calendar }) => {
    if (isChosenCalendar(calendar)) return true;
    if (!calendar.deleted && !calendar.hidden && calendar.selected && isGoogleMade(calendar)) warnings.add("calendarsSkipped");
    return false;
  });
  // The primary calendar first, then Google's order.
  chosen.sort((a, b) => Number(b.calendar.primary === true) - Number(a.calendar.primary === true));

  chosen.forEach(({ calendar, events, series }, calendarIndex) => {
    const projectKey = nativeKey("calendar", calendar.id);
    projects.push({
      key: projectKey,
      name: fitName(calendar.summaryOverride || calendar.summary || "", LIMITS.projectName) || "Google Calendar",
      kind: "project",
      parentKey: null,
      view: "calendar",
      sortOrder: calendarIndex,
      archived: false,
    });

    const own: ImportedTask[] = [];
    const add = (e: GoogleEvent, key: string, due: Due, recurrence: string | null) => {
      const title = e.summary?.trim();
      if (!title) {
        warnings.add("untitledSkipped");
        return;
      }
      own.push({
        key,
        projectKey,
        sectionKey: null,
        parentKey: null,
        title,
        notes: notesOf(e),
        priority: 0,
        tags: [],
        dueDate: due.dueDate,
        dueTime: due.dueTime,
        startDate: recurrence ? null : due.startDate,
        recurrence,
        done: false,
        completedAt: null,
        sortOrder: 0,
        reminders: [],
      });
    };
    const live = (e: GoogleEvent) => e.status !== "cancelled" && !SKIPPED_TYPES.has(e.eventType ?? "");

    const occurrences = new Map<string, GoogleEvent[]>();
    for (const e of events) {
      if (!e.recurringEventId || !live(e)) continue;
      occurrences.set(e.recurringEventId, [...(occurrences.get(e.recurringEventId) ?? []), e]);
    }
    const withExceptions = new Set(series.filter((e) => e.recurringEventId).map((e) => e.recurringEventId!));
    const handled = new Set<string>();

    for (const master of series) {
      if (!master.recurrence?.length || !live(master)) continue;
      const list = (occurrences.get(master.id) ?? []).sort((a, b) => startKey(a).localeCompare(startKey(b)));
      handled.add(master.id);
      if (list.length === 0) continue;
      const repeating = seriesRule(master, list, withExceptions.has(master.id), data.today, zone);
      if (repeating) {
        // The series' own title and notes; the next occurrence's day and time.
        add(master, nativeKey("event", master.id), repeating.due, repeating.rule);
        continue;
      }
      expanded++;
      for (const o of list) {
        const due = dueOf(o, zone);
        if (due) add(o, nativeKey("event", o.id), due, null);
      }
    }
    for (const e of events) {
      if (!live(e) || (e.recurringEventId && handled.has(e.recurringEventId))) continue;
      // Single events, and occurrences whose series Google did not list: each a task of its own.
      const due = dueOf(e, zone);
      if (due) add(e, nativeKey("event", e.id), due, null);
    }
    own.sort((a, b) => `${a.dueDate}${a.dueTime ?? ""}`.localeCompare(`${b.dueDate}${b.dueTime ?? ""}`));
    own.forEach((t, i) => {
      t.sortOrder = i;
      tasks.push(t);
    });
  });
  if (expanded) warnings.add("seriesExpanded", expanded);
  return { projects, sections: [], tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

const EVENT_FIELDS = "items(id,status,summary,description,location,start,end,recurrence,recurringEventId,originalStartTime,eventType),nextPageToken";

async function allPages<T>(provider: Provider, url: URL): Promise<T[]> {
  const out: T[] = [];
  for (let page = 0; page < MAX_PAGES; page++) {
    const body = await providerGet<{ items?: T[]; nextPageToken?: string }>(provider, url.toString());
    out.push(...(body?.items ?? []));
    if (!body?.nextPageToken) break;
    url.searchParams.set("pageToken", body.nextPageToken);
  }
  return out;
}

export const googleCalendar: TokenSource = {
  id: "google-calendar",
  label: "Google Calendar",
  refSource: "google-calendar",
  input: "oauth",
  async load(token, ctx) {
    const provider: Provider = { label: "Google Calendar", fetch: ctx.fetch, headers: { Authorization: `Bearer ${token}` } };
    const now = Date.now();
    const timeMin = new Date(now - CALENDAR_PAST_DAYS * 86_400_000).toISOString();
    const timeMax = new Date(now + CALENDAR_FUTURE_DAYS * 86_400_000).toISOString();
    const list = await allPages<CalendarEntry>(provider, new URL(`${CALENDAR_API}/users/me/calendarList?maxResults=250`));
    const calendars: GoogleCalendarData["calendars"] = [];
    for (const calendar of list) {
      if (!isChosenCalendar(calendar)) {
        calendars.push({ calendar, events: [], series: [] });
        continue;
      }
      const eventsUrl = (singleEvents: boolean) => {
        const url = new URL(`${CALENDAR_API}/calendars/${encodeURIComponent(calendar.id)}/events`);
        url.searchParams.set("timeMin", timeMin);
        url.searchParams.set("timeMax", timeMax);
        url.searchParams.set("singleEvents", String(singleEvents));
        url.searchParams.set("maxResults", "2500");
        url.searchParams.set("fields", EVENT_FIELDS);
        return url;
      };
      const [events, series] = await Promise.all([
        allPages<GoogleEvent>(provider, eventsUrl(true)),
        allPages<GoogleEvent>(provider, eventsUrl(false)),
      ]);
      calendars.push({ calendar, events, series });
    }
    return mapGoogleCalendar({ today: zonedDateTime(now, ctx.timeZone).date, calendars }, ctx);
  },
};
