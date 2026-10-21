import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import type { ZimamBackend } from "./backend";

declare global {
  namespace Cloudflare {
    interface Env {
      OAUTH_KV: KVNamespace;
      /** Set by the OAuth provider for the default handler. */
      OAUTH_PROVIDER: OAuthHelpers;
      API: ZimamBackend;
      /** Public origin of this worker, e.g. https://mcp.zimam.work. */
      MCP_ORIGIN: string;
      APPLE_WEB_CLIENT_ID: string;
      /** Google OAuth web client ID for the consent page; empty hides Sign in with Google. */
      GOOGLE_WEB_CLIENT_ID: string;
    }
  }
}

export type Env = Cloudflare.Env;

/** What a Zimam grant carries to the MCP handler. */
export interface GrantProps {
  userId: string;
}

export const SCOPES = {
  read: "tasks:read",
  write: "tasks:write",
} as const;
