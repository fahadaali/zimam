import type { JWTVerifyGetKey } from "jose";
import type { AiProvider } from "./ai/provider";
import type { AppleTokens } from "./auth/apple-tokens";
import type { Access } from "./data/access";
import type { Mutator } from "./data/mutations";
import type { Env } from "./env";
import type { PushSender } from "./push/apns";
import type { Realtime } from "./realtime/notify";

export interface Deps {
  /** Sign in with Apple signing keys; tests pass a local key set. */
  appleKeys: JWTVerifyGetKey;
  /** The in-app assistant's model provider, built from the Worker's vars and secrets; tests pass a fake. */
  ai: (env: Env) => AiProvider;
  /**
   * Sign in with Apple's token and revoke endpoints, or null when the Apple key
   * secrets are missing (sign-in and account deletion then skip Apple). Tests pass a fake.
   */
  appleTokens: (env: Env) => AppleTokens | null;
  /** APNs for reminder pushes (null when its secrets are missing); tests pass a fake. */
  push?: (env: Env) => PushSender | null;
  /** Realtime "pull now" nudges after writes (src/realtime/); none when absent. Tests pass a fake or the real channel. */
  realtime?: (env: Env) => Realtime | null;
}

export interface AppEnv {
  Bindings: Env;
  Variables: {
    deps: Deps;
    token: string;
    userId: string;
    access: Access;
    mutator: Mutator;
  };
}
