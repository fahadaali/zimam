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
      /** The web app's Sign in with Apple redirect URI (its /app page); a web code is exchanged with it. Not a secret. */
      APPLE_WEB_REDIRECT_URI?: string;
      /** Comma-separated other redirect URIs a client may say it used (the MCP consent page's /authorize). */
      APPLE_REDIRECT_URIS?: string;
      /**
       * Comma-separated Google OAuth client IDs whose ID tokens sign in (iOS, web). Not secrets.
       * Empty turns Sign in with Google off (503 `google_unavailable`).
       */
      GOOGLE_CLIENT_IDS: string;
      /** Comma-separated browser origins allowed to call the API. */
      ALLOWED_ORIGINS: string;
      /** In-app assistant provider: "anthropic" or "deepseek". */
      AI_PROVIDER: string;
      /** Cloudflare AI Gateway base URL, without the provider path. */
      AI_GATEWAY_URL: string;
      /** Assistant requests allowed per user per calendar month (UTC), when no plan limit is set. */
      AI_MONTHLY_LIMIT: string;
      /** The monthly limit for a free user when SUBSCRIPTIONS_ENFORCED is "true"; "0" keeps the assistant pro-only. */
      AI_MONTHLY_LIMIT_FREE?: string;
      /** The monthly limit for pro, and for everyone while SUBSCRIPTIONS_ENFORCED is not "true". */
      AI_MONTHLY_LIMIT_PRO?: string;
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
      /** R2 bucket zimam-attachments: task attachments (src/attachments.ts). */
      ATTACHMENTS: R2Bucket;
      /** Attachment storage per uploader in MB for a free user when SUBSCRIPTIONS_ENFORCED is "true" (default 1024). */
      ATTACHMENT_QUOTA_MB_FREE?: string;
      /** Attachment storage per uploader in MB for pro, and for everyone while not enforced (default 10240). */
      ATTACHMENT_QUOTA_MB_PRO?: string;
      /** The app's bundle id: App Store transactions must be for it. Not a secret. */
      APPSTORE_BUNDLE_ID: string;
      /** Secret (`wrangler secret put`): the In-App Purchase key's id (App Store Server API). */
      APPSTORE_KEY_ID?: string;
      /** Secret (`wrangler secret put`): the App Store Connect issuer id. */
      APPSTORE_ISSUER_ID?: string;
      /** Secret (`wrangler secret put`): the In-App Purchase key, the .p8 file's PEM text. */
      APPSTORE_PRIVATE_KEY?: string;
      /** "true" makes pro features need «زمام الاحترافية»; anything else lets everyone use them (personal trial). */
      SUBSCRIPTIONS_ENFORCED: string;
      /** Comma-separated user ids or emails treated as pro whatever their subscription (the owner). */
      PRO_USERS?: string;
    }
  }
}

export type Env = Cloudflare.Env;
