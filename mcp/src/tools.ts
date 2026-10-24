import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { Outcome, ZimamBackend } from "./backend";

const INSTRUCTIONS = `Zimam (زمام) is an Arabic-first task manager. Talk to the user in their language; Zimam's own texts are Arabic.
- Call get_agenda first when you need today's date: it answers in the user's time zone with both calendars and prayer times.
- Dates you send are Gregorian YYYY-MM-DD in the user's local time; every task you get back also carries its Hijri (Umm al-Qura) date. Show both, Hijri first unless the user prefers Gregorian, separated by the Arabic comma «،».
- A task can be tied to a prayer instead of a clock time: duePrayer (fajr, dhuhr, asr, maghrib, isha) plus duePrayerOffset in minutes (positive = after, negative = before). "After Asr by 20 minutes" is duePrayer=asr, duePrayerOffset=20.
- A task can span days: startDate is its first day and dueDate its last (startDate needs a dueDate on or after it).
- Completing a repeating task (complete_task, or update_task with status done) adds its next occurrence by itself, with the same reminders, as the app does. Do not create it.
- A reminder can be tied to one of the user's saved places («البيت», «العمل», «الاستراحة»): add_place_reminder fires on arriving at or leaving it. With a date and time too, it fires once, at whichever comes first: arriving before the time, or the time before arriving. Places are added only in the Zimam app (Settings, «أماكني»); list_places shows them.
- Never invent ids: look tasks, projects and places up with list_tasks, search_tasks, list_projects or list_places.`;

const PRAYER = z.enum(["fajr", "dhuhr", "asr", "maghrib", "isha"]);
const DAY = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "YYYY-MM-DD");
const TIME = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, "HH:mm");
const PRIORITY = z.enum(["none", "low", "medium", "high"]);

const taskFields = {
  notes: z.string().max(20_000).nullable().optional().describe("Free-text notes."),
  projectId: z.string().nullable().optional().describe("Project id from list_projects; null for the inbox."),
  parentId: z.string().nullable().optional().describe("Parent task id, to make this a subtask."),
  dueDate: DAY.nullable().optional().describe("Due day, Gregorian YYYY-MM-DD in the user's time zone; null to clear."),
  startDate: DAY.nullable()
    .optional()
    .describe("First day of a task that spans days (a trip, a project phase), on or before dueDate; it needs a dueDate. null to make it a one-day task."),
  dueTime: TIME.nullable().optional().describe("Due time HH:mm (24h), local."),
  duePrayer: PRAYER.nullable().optional().describe("Tie the task to a prayer instead of a clock time."),
  duePrayerOffset: z.number().int().min(-720).max(720).nullable().optional().describe("Minutes after (+) or before (-) duePrayer."),
  priority: PRIORITY.optional(),
  tags: z.array(z.string().min(1).max(50)).max(30).optional(),
  recurrence: z.string().max(500).nullable().optional().describe('RFC 5545 RRULE, e.g. "FREQ=WEEKLY;BYDAY=TH".'),
};

function answer<T>(outcome: Outcome<T>): CallToolResult {
  if (!outcome.ok) {
    return { isError: true, content: [{ type: "text", text: `${outcome.error.code}: ${outcome.error.message}` }] };
  }
  return { content: [{ type: "text", text: JSON.stringify(outcome.value, null, 2) }] };
}

/**
 * The Zimam MCP server for one signed-in user. Write tools exist only when the grant
 * includes `tasks:write`, so a read-only connection cannot change anything.
 */
export function buildServer(backend: ZimamBackend, userId: string, canWrite: boolean): McpServer {
  const server = new McpServer({ name: "zimam", version: "1.0.0" }, { instructions: INSTRUCTIONS });
  const readOnly = { readOnlyHint: true, openWorldHint: false };

  server.registerTool(
    "list_tasks",
    {
      title: "List tasks",
      description:
        "List the user's Zimam tasks: open ones by default, dated tasks first. Filter by project (id, or \"inbox\" for tasks outside projects), status, or a due-date range.",
      inputSchema: {
        projectId: z.string().optional().describe('Project id, or "inbox".'),
        status: z.enum(["open", "done", "all"]).optional().describe("Default open."),
        from: DAY.optional().describe("Earliest due day, inclusive."),
        to: DAY.optional().describe("Latest due day, inclusive."),
        limit: z.number().int().min(1).max(200).optional().describe("Default 50."),
      },
      annotations: readOnly,
    },
    async (args) => answer(await backend.listTasks(userId, args)),
  );

  server.registerTool(
    "search_tasks",
    {
      title: "Search tasks",
      description:
        "Search task titles, notes and tags. Arabic matching ignores diacritics, tatweel and alef/taa-marbuta/yaa forms, and treats Arabic-Indic digits as Latin.",
      inputSchema: {
        query: z.string().min(1).max(200),
        includeDone: z.boolean().optional().describe("Also return completed tasks. Default false."),
        limit: z.number().int().min(1).max(200).optional(),
      },
      annotations: readOnly,
    },
    async ({ query, includeDone, limit }) =>
      answer(await backend.listTasks(userId, { query, status: includeDone ? "all" : "open", limit })),
  );

  server.registerTool(
    "list_projects",
    {
      title: "List projects",
      description: "List the user's projects and folders with their role (owner, editor, viewer) and how many top-level tasks are done.",
      inputSchema: {},
      annotations: readOnly,
    },
    async () => answer(await backend.listProjects(userId)),
  );

  server.registerTool(
    "get_agenda",
    {
      title: "Get agenda",
      description:
        "The user's schedule for one or more days: each day in Hijri and Gregorian, its five prayer times (when the user has shared a location in the app), tasks due that day, and overdue open tasks. Without `from` it starts today in the user's time zone.",
      inputSchema: {
        from: DAY.optional().describe("First day, Gregorian YYYY-MM-DD. Default today."),
        days: z.number().int().min(1).max(14).optional().describe("How many days, 1 to 14. Default 1."),
      },
      annotations: readOnly,
    },
    async (args) => answer(await backend.getAgenda(userId, args)),
  );

  server.registerTool(
    "list_places",
    {
      title: "List saved places",
      description:
        "The user's saved places («أماكني») by name, such as «البيت» or «العمل», for location reminders. The user adds and moves places in the Zimam app.",
      inputSchema: {},
      annotations: readOnly,
    },
    async () => answer(await backend.listPlaces(userId)),
  );

  if (!canWrite) return server;

  const writes = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };

  server.registerTool(
    "create_task",
    {
      title: "Create task",
      description: "Add a task. Give a due day and optionally a time, or tie it to a prayer with duePrayer and duePrayerOffset.",
      inputSchema: { title: z.string().min(1).max(500), ...taskFields },
      annotations: writes,
    },
    async (args) => answer(await backend.createTask(userId, args)),
  );

  server.registerTool(
    "update_task",
    {
      title: "Update task",
      description:
        "Change a task: rename it, move it to another project, postpone it to another day, change its priority, or reopen it. Only the fields you pass change.",
      inputSchema: {
        id: z.string().describe("Task id."),
        title: z.string().min(1).max(500).optional(),
        status: z.enum(["todo", "doing", "done"]).optional(),
        ...taskFields,
      },
      annotations: { ...writes, idempotentHint: true },
    },
    async ({ id, ...fields }) => answer(await backend.updateTask(userId, id, fields)),
  );

  server.registerTool(
    "add_place_reminder",
    {
      title: "Add place reminder",
      description:
        "Remind the user about a task when they arrive at or leave one of their saved places (\"remind me to buy bread when I get home\"). Add date and time to make it fire once at whichever comes first: arriving, or the time. The place must already be saved in the app; if it is not, tell the user to add it under «أماكني» in Zimam's settings.",
      inputSchema: {
        taskId: z.string().describe("Task id. Create the task first with create_task if needed."),
        place: z.string().min(1).max(200).describe("A saved place's id or name from list_places."),
        trigger: z.enum(["arrive", "leave"]).optional().describe("Default arrive."),
        date: DAY.optional().describe("Also remind on this local day; it fires at whichever comes first."),
        time: TIME.optional().describe("Local HH:mm with date. Default 09:00."),
      },
      annotations: writes,
    },
    async (args) => answer(await backend.addPlaceReminder(userId, args)),
  );

  server.registerTool(
    "complete_task",
    {
      title: "Complete task",
      description: "Mark a task done. A repeating task gets its next occurrence added by itself.",
      inputSchema: { id: z.string().describe("Task id.") },
      annotations: { ...writes, idempotentHint: true },
    },
    async ({ id }) => answer(await backend.completeTask(userId, id)),
  );

  return server;
}
