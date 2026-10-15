import { providerFromEnv } from "./ai/provider";
import { createApp } from "./app";
import { appleKeys } from "./auth/apple";
import { appleTokensFromEnv } from "./auth/apple-tokens";
import { googleKeys } from "./auth/google";
import type { Env } from "./env";
import { importsFromEnv } from "./imports/jobs";
import { handleImportBatch } from "./imports/queue";
import { apnsFromEnv } from "./push/apns";
import { sendDueReminders } from "./push/reminders";
import { channelRealtime, latestSeq, notifyChangesSince } from "./realtime/notify";
import type { Deps } from "./types";

const deps: Deps = {
  appleKeys,
  googleKeys,
  ai: (env) => providerFromEnv(env),
  appleTokens: (env) => appleTokensFromEnv(env),
  push: (env) => apnsFromEnv(env),
  realtime: (env) => channelRealtime(env.USER_CHANNEL),
};
const app = createApp(deps);

export default {
  fetch: app.fetch,
  /** Every 5 minutes: reminder pushes beyond the app's local window (src/push/reminders.ts). */
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(sendDueReminders(env.DB, deps.push?.(env) ?? null, controller.scheduledTime));
  },
  /**
   * zimam-imports and its dead-letter queue (src/imports/queue.ts). Imports write outside
   * `requireUser`, so they nudge the importing user's devices (and project members) here.
   */
  async queue(batch, env, ctx) {
    const since = await latestSeq(env.DB);
    try {
      await handleImportBatch(batch, env, deps.imports?.(env) ?? importsFromEnv(env));
    } finally {
      const realtime = deps.realtime?.(env);
      if (realtime && since !== null) ctx.waitUntil(notifyChangesSince(env.DB, realtime, since));
    }
  },
} satisfies ExportedHandler<Env>;
export { ZimamService } from "./service";
export { UserChannel } from "./realtime/channel";
