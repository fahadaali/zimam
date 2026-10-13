declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      /** Comma-separated Sign in with Apple audiences (bundle id, web Services ID). */
      APPLE_AUDIENCES: string;
      /** Comma-separated browser origins allowed to call the API. */
      ALLOWED_ORIGINS: string;
    }
  }
}

export type Env = Cloudflare.Env;
