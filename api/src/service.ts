import { WorkerEntrypoint } from "cloudflare:workers";
import { Assistant, type AgendaRequest, type TaskFields, type TaskFilter } from "./assistant";
import { appleKeys } from "./auth/apple";
import type { Env } from "./env";
import { channelRealtime, latestSeq, notifyChangesSince } from "./realtime/notify";

/**
 * RPC entrypoint for the MCP worker (`mcp/`), reached only through its service binding,
 * never from the internet. The MCP worker passes the user id from the OAuth grant it validated.
 */
export class ZimamService extends WorkerEntrypoint<Env> {
  private get assistant() {
    return new Assistant(this.env, appleKeys);
  }

  /** Runs a write, then (after returning) tells everyone who can see what it changed to pull. */
  private async writing<T>(work: () => Promise<T>): Promise<T> {
    const since = await latestSeq(this.env.DB);
    try {
      return await work();
    } finally {
      if (since !== null) {
        this.ctx.waitUntil(notifyChangesSince(this.env.DB, channelRealtime(this.env.USER_CHANNEL), since));
      }
    }
  }

  signInWithApple(identityToken: string, nonce: string) {
    return this.assistant.signInWithApple(identityToken, nonce);
  }

  listTasks(userId: string, filter: TaskFilter) {
    return this.assistant.listTasks(userId, filter);
  }

  createTask(userId: string, fields: TaskFields) {
    return this.writing(() => this.assistant.createTask(userId, fields));
  }

  updateTask(userId: string, id: string, fields: TaskFields) {
    return this.writing(() => this.assistant.updateTask(userId, id, fields));
  }

  completeTask(userId: string, id: string) {
    return this.writing(() => this.assistant.completeTask(userId, id));
  }

  listProjects(userId: string) {
    return this.assistant.listProjects(userId);
  }

  getAgenda(userId: string, request: AgendaRequest) {
    return this.assistant.getAgenda(userId, request);
  }
}
