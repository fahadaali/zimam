import type { JWTVerifyGetKey } from "jose";
import type { AiProvider } from "./ai/provider";
import type { AppleTokens } from "./auth/apple-tokens";
import type { Access } from "./data/access";
import type { Mutator } from "./data/mutations";
import type { Env } from "./env";

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
