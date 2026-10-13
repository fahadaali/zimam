import { providerFromEnv } from "./ai/provider";
import { createApp } from "./app";
import { appleKeys } from "./auth/apple";
import { appleTokensFromEnv } from "./auth/apple-tokens";
import type { Env } from "./env";
import { apnsFromEnv } from "./push/apns";
import { sendDueReminders } from "./push/reminders";
import { channelRealtime } from "./realtime/notify";
import type { Deps } from "./types";

const deps: Deps = {
  appleKeys,
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
} satisfies ExportedHandler<Env>;
export { ZimamService } from "./service";
export { UserChannel } from "./realtime/channel";
