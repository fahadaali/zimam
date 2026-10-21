import type { Source, SourceId } from "../source";
import { asana } from "./asana";
import { clickup } from "./clickup";
import { genericCsv } from "./generic-csv";
import { googleCalendar } from "./google-calendar";
import { googleTasks, googleTasksApi } from "./google-tasks";
import { jira } from "./jira";
import { linear } from "./linear";
import { microsoftTodo } from "./microsoft-todo";
import { monday } from "./monday";
import { notion } from "./notion";
import { planner } from "./planner";
import { tickTickCsv } from "./ticktick";
import { tickTickApi } from "./ticktick-api";
import { todoistApi, todoistCsv, todoistOAuth } from "./todoist";
import { trello } from "./trello";

/**
 * Every source the API accepts, in the order the apps list them. The OAuth ones get their
 * token from the server's OAuth flow (src/imports/oauth.ts); Apple Reminders and Apple
 * Calendar are imported on the device (EventKit).
 */
export const SOURCES: Record<SourceId, Source> = {
  "todoist-oauth": todoistOAuth,
  "todoist-csv": todoistCsv,
  "todoist-api": todoistApi,
  "ticktick-csv": tickTickCsv,
  "google-tasks-api": googleTasksApi,
  "google-tasks": googleTasks,
  csv: genericCsv,
  "google-calendar": googleCalendar,
  "microsoft-todo": microsoftTodo,
  notion,
  trello,
  asana,
  clickup,
  planner,
  jira,
  linear,
  monday,
  "ticktick-api": tickTickApi,
};

export const isSourceId = (id: unknown): id is SourceId => typeof id === "string" && Object.hasOwn(SOURCES, id);
