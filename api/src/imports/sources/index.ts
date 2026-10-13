import type { Source, SourceId } from "../source";
import { genericCsv } from "./generic-csv";
import { googleTasks } from "./google-tasks";
import { tickTickCsv } from "./ticktick";
import { todoistApi, todoistCsv } from "./todoist";

/**
 * Every source the API accepts. OAuth providers (Trello, Asana, Notion, Microsoft
 * To Do) will be added here as `TokenSource`s with `input: "oauth"` once the app runs
 * their OAuth flows; Apple Reminders is imported on the device (EventKit).
 */
export const SOURCES: Record<SourceId, Source> = {
  "todoist-csv": todoistCsv,
  "todoist-api": todoistApi,
  "ticktick-csv": tickTickCsv,
  "google-tasks": googleTasks,
  csv: genericCsv,
};

export const isSourceId = (id: unknown): id is SourceId => typeof id === "string" && Object.hasOwn(SOURCES, id);
