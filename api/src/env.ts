declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      /** Comma-separated Sign in with Apple audiences (bundle id, web Services ID). */
      APPLE_AUDIENCES: string;
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
    }
  }
}

export type Env = Cloudflare.Env;
