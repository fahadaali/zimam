import { WorkerEntrypoint } from "cloudflare:workers";
import {
  Assistant,
  type AgendaRequest,
  type Outcome,
  type PlaceReminderRequest,
  type SignInKeys,
  type TaskFields,
  type TaskFilter,
} from "./assistant";
import type { AppleCode } from "./auth/account";
import { appleKeys } from "./auth/apple";
import { type AppleTokens, appleTokensFromEnv } from "./auth/apple-tokens";
import { googleKeys } from "./auth/google";
import type { Env } from "./env";
import { channelRealtime, latestSeq, notifyChangesSince } from "./realtime/notify";
import { hasProAccess, PRO_REQUIRED } from "./subscriptions/entitlements";

/**
 * RPC entrypoint for the MCP worker (`mcp/`), reached only through its service binding,
 * never from the internet. The MCP worker passes the user id from the OAuth grant it validated.
 */
export class ZimamService extends WorkerEntrypoint<Env> {
  /** Apple's and Google's signing keys; tests replace them with local key sets. */
  static keys: SignInKeys = { apple: appleKeys, google: googleKeys };
  /** Sign in with Apple's token endpoint; tests replace it with a fake. */
  static appleTokens: (env: Env) => AppleTokens | null = (env) => appleTokensFromEnv(env);

  private get assistant() {
    return new Assistant(this.env, ZimamService.keys, ZimamService.appleTokens);
  }

  /**
   * MCP is a «زمام الاحترافية» feature: when SUBSCRIPTIONS_ENFORCED is "true", a free user's
   * tool calls answer `pro_required` with an Arabic message the assistant shows as is.
   * Signing in stays open, so the user can connect and then subscribe.
   */
  private async pro<T>(userId: string, work: () => Promise<Outcome<T>>): Promise<Outcome<T>> {
    if (!(await hasProAccess(this.env, userId))) {
      return { ok: false, error: { code: PRO_REQUIRED.code, message: PRO_REQUIRED.arabic } };
    }
    return work();
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

  /** `code`: the consent page's authorization code and the redirect URI it used, when it sends them. */
  signInWithApple(identityToken: string, nonce: string, code?: AppleCode) {
    return this.assistant.signInWithApple(identityToken, nonce, code);
  }

  signInWithGoogle(idToken: string, nonce: string) {
    return this.assistant.signInWithGoogle(idToken, nonce);
  }

  listTasks(userId: string, filter: TaskFilter) {
    return this.pro(userId, () => this.assistant.listTasks(userId, filter));
  }

  createTask(userId: string, fields: TaskFields) {
    return this.pro(userId, () => this.writing(() => this.assistant.createTask(userId, fields)));
  }

  updateTask(userId: string, id: string, fields: TaskFields) {
    return this.pro(userId, () => this.writing(() => this.assistant.updateTask(userId, id, fields)));
  }

  completeTask(userId: string, id: string) {
    return this.pro(userId, () => this.writing(() => this.assistant.completeTask(userId, id)));
  }

  listProjects(userId: string) {
    return this.pro(userId, () => this.assistant.listProjects(userId));
  }

  listPlaces(userId: string) {
    return this.pro(userId, () => this.assistant.listPlaces(userId));
  }

  addPlaceReminder(userId: string, request: PlaceReminderRequest) {
    return this.pro(userId, () => this.writing(() => this.assistant.addPlaceReminder(userId, request)));
  }

  getAgenda(userId: string, request: AgendaRequest) {
    return this.pro(userId, () => this.assistant.getAgenda(userId, request));
  }
}
