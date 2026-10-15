import type { UserChannel } from "./realtime/channel";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      /** Comma-separated Sign in with Apple audiences (bundle id, web Services ID). */
      APPLE_AUDIENCES: string;
      /** Apple developer team id; signs the Sign in with Apple client secret. Not a secret. */
      APPLE_TEAM_ID: string;
      /** Secret (`wrangler secret put`): the Sign in with Apple key id. */
      APPLE_KEY_ID?: string;
      /** Secret (`wrangler secret put`): the Sign in with Apple key, the .p8 file's PEM text. */
      APPLE_PRIVATE_KEY?: string;
      /** Comma-separated browser origins allowed to call the API. */
      ALLOWED_ORIGINS: string;
      /** In-app assistant provider: "anthropic" or "deepseek". */
      AI_PROVIDER: string;
      /** Cloudflare AI Gateway base URL, without the provider path. */
      AI_GATEWAY_URL: string;
      /** Assistant requests allowed per user per calendar month (UTC). */
      AI_MONTHLY_LIMIT: string;
      /** Optional model override for the chosen provider. */
      AI_MODEL?: string;
      /** Secret (`wrangler secret put`). */
      ANTHROPIC_API_KEY?: string;
      /** Secret (`wrangler secret put`). */
      DEEPSEEK_API_KEY?: string;
      /** Secret for an authenticated gateway, sent as `cf-aig-authorization`. */
      AI_GATEWAY_TOKEN?: string;
      /** Apple Developer team id, for the APNs provider token. */
      APNS_TEAM_ID: string;
      /** Secret (`wrangler secret put`): the APNs key's id. Pushes are skipped without it. */
      APNS_KEY_ID?: string;
      /** Secret (`wrangler secret put`): the APNs .p8 key (PKCS #8 PEM). */
      APNS_PRIVATE_KEY?: string;
      /** Realtime sync: one `UserChannel` Durable Object per user, holding their WebSockets. */
      USER_CHANNEL: DurableObjectNamespace<UserChannel>;
      /** Producer for the zimam-imports queue (src/imports/queue.ts). */
      IMPORTS: Queue;
      /** R2 bucket zimam-imports: uploaded exports and parsed imports, deleted when the job ends. */
      IMPORT_FILES: R2Bucket;
    }
  }
}

export type Env = Cloudflare.Env;
