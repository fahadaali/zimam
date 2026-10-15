/**
 * The API worker's RPC surface (`api/src/service.ts`, class ZimamService), as this worker uses it.
 * Keep these shapes in step with `api/src/assistant.ts`.
 */

export type Outcome<T> = { ok: true; value: T } | { ok: false; error: { code: string; message: string } };

export type PrayerName = "fajr" | "dhuhr" | "asr" | "maghrib" | "isha";
export type PriorityName = "none" | "low" | "medium" | "high";

export interface AssistantTask {
  id: string;
  title: string;
  notes: string | null;
  status: "todo" | "doing" | "done";
  priority: PriorityName;
  tags: string[];
  projectId: string | null;
  project: string | null;
  parentId: string | null;
  due: { date: string; time: string | null; hijri: string; gregorian: string } | null;
  prayer: { prayer: string; offsetMinutes: number; text: string } | null;
  recurrence: string | null;
  completedAt: string | null;
}

export interface AssistantProject {
  id: string;
  name: string;
  kind: string;
  role: string;
  view: string;
  taskCount: number;
  doneCount: number;
}

export interface Agenda {
  timeZone: string;
  hasLocation: boolean;
  overdue: AssistantTask[];
  days: {
    date: string;
    weekday: string;
    label: string;
    hijri: string;
    gregorian: string;
    prayers: Record<PrayerName, string> | null;
    tasks: AssistantTask[];
  }[];
}

export interface TaskFilter {
  projectId?: string;
  status?: "open" | "done" | "all";
  from?: string;
  to?: string;
  query?: string;
  limit?: number;
}

export interface TaskFields {
  title?: string;
  notes?: string | null;
  projectId?: string | null;
  parentId?: string | null;
  dueDate?: string | null;
  dueTime?: string | null;
  duePrayer?: PrayerName | null;
  duePrayerOffset?: number | null;
  priority?: PriorityName;
  tags?: string[];
  status?: "todo" | "doing" | "done";
  recurrence?: string | null;
}

export interface ZimamBackend {
  signInWithApple(identityToken: string, nonce: string): Promise<Outcome<{ userId: string; name: string | null }>>;
  /** Verifies a Google ID token whose nonce claim is the SHA-256 (hex) of `nonce`. */
  signInWithGoogle(idToken: string, nonce: string): Promise<Outcome<{ userId: string; name: string | null }>>;
  listTasks(userId: string, filter: TaskFilter): Promise<Outcome<AssistantTask[]>>;
  createTask(userId: string, fields: TaskFields): Promise<Outcome<AssistantTask>>;
  updateTask(userId: string, id: string, fields: TaskFields): Promise<Outcome<AssistantTask>>;
  completeTask(userId: string, id: string): Promise<Outcome<AssistantTask>>;
  listProjects(userId: string): Promise<Outcome<AssistantProject[]>>;
  getAgenda(userId: string, request: { from?: string; days?: number }): Promise<Outcome<Agenda>>;
}
