// REST calls for the assistant, sharing, the board and the calendar (api/DEVELOPMENT.md). Kept out
// of api.js so the features stay in their own modules. Sections have no REST route: they are written
// through POST /v1/sync like the app does, each as one mutation with its own result.
import { allTasks, ApiError, request } from "./api.js";

const id = encodeURIComponent;

export const assistantApi = {
  parse: (text, now) => request("POST", "/v1/assistant/parse", { text, now }),
  breakdown: (taskId) => request("POST", "/v1/assistant/breakdown", { taskId }),
  summary: (date) => request("GET", `/v1/assistant/summary?date=${id(date)}`),
};

export const sharingApi = {
  members: (projectId) => request("GET", `/v1/projects/${id(projectId)}/members`),
  setRole: (projectId, userId, role) => request("PATCH", `/v1/projects/${id(projectId)}/members/${id(userId)}`, { role }),
  removeMember: (projectId, userId) => request("DELETE", `/v1/projects/${id(projectId)}/members/${id(userId)}`),
  invites: (projectId) => request("GET", `/v1/projects/${id(projectId)}/invites`),
  createInvite: (projectId, role) => request("POST", `/v1/projects/${id(projectId)}/invites`, { role }),
  revokeInvite: (projectId, inviteId) => request("DELETE", `/v1/projects/${id(projectId)}/invites/${id(inviteId)}`),
  comments: (taskId) => request("GET", `/v1/tasks/${id(taskId)}/comments`),
  addComment: (taskId, body) => request("POST", `/v1/tasks/${id(taskId)}/comments`, { body }),
  deleteComment: (commentId) => request("DELETE", `/v1/comments/${id(commentId)}`),
};

export const boardApi = {
  /** The project with its role and sections. */
  project: (projectId) => request("GET", `/v1/projects/${id(projectId)}`),
  setView: (projectId, view) => request("PATCH", `/v1/projects/${id(projectId)}`, { view }),
  patchTask: (taskId, fields) => request("PATCH", `/v1/tasks/${id(taskId)}`, fields),
  completeTask: (taskId) => request("POST", `/v1/tasks/${id(taskId)}/complete`),
  createTask: (task) => request("POST", "/v1/tasks", task),
  tasks: (params) => allTasks(params),
  /** Section upserts and deletes through sync; throws the first mutation that was not applied. */
  async sections(mutations) {
    if (mutations.length === 0) return;
    const { results } = await request("POST", "/v1/sync", { mutations });
    const failed = results.find((r) => r.status !== "applied");
    if (failed) throw new ApiError(400, failed.status, failed.message ?? failed.status);
  },
};

/** A section's next `updatedAt`: now, and always after the version it replaces. */
export const nextUpdatedAt = (current) => Math.max(Date.now(), (current ?? 0) + 1);

/** A task's reminders: read through REST, written through sync like the apps (reminders are personal). */
export const remindersApi = {
  list: (taskId) => request("GET", `/v1/tasks/${id(taskId)}/reminders`),
  async save(mutations) {
    const { results } = await request("POST", "/v1/sync", { mutations });
    const failed = results.find((r) => r.status !== "applied");
    if (failed) throw new ApiError(400, failed.status, failed.message ?? failed.status);
  },
  add: (reminder) => remindersApi.save([{ op: "upsert", entity: "reminder", data: reminder }]),
  remove: (reminder) => remindersApi.save([{ op: "delete", entity: "reminder", id: reminder.id, updatedAt: nextUpdatedAt(reminder.updatedAt) }]),
};
