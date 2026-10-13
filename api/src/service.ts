import { WorkerEntrypoint } from "cloudflare:workers";
import { Assistant, type AgendaRequest, type TaskFields, type TaskFilter } from "./assistant";
import { appleKeys } from "./auth/apple";
import type { Env } from "./env";

/**
 * RPC entrypoint for the MCP worker (`mcp/`), reached only through its service binding,
 * never from the internet. The MCP worker passes the user id from the OAuth grant it validated.
 */
export class ZimamService extends WorkerEntrypoint<Env> {
  private get assistant() {
    return new Assistant(this.env, appleKeys);
  }

  signInWithApple(identityToken: string, nonce: string) {
    return this.assistant.signInWithApple(identityToken, nonce);
  }

  listTasks(userId: string, filter: TaskFilter) {
    return this.assistant.listTasks(userId, filter);
  }

  createTask(userId: string, fields: TaskFields) {
    return this.assistant.createTask(userId, fields);
  }

  updateTask(userId: string, id: string, fields: TaskFields) {
    return this.assistant.updateTask(userId, id, fields);
  }

  completeTask(userId: string, id: string) {
    return this.assistant.completeTask(userId, id);
  }

  listProjects(userId: string) {
    return this.assistant.listProjects(userId);
  }

  getAgenda(userId: string, request: AgendaRequest) {
    return this.assistant.getAgenda(userId, request);
  }
}
