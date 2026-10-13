import type { JWTVerifyGetKey } from "jose";
import type { AiProvider } from "./ai/provider";
import type { Access } from "./data/access";
import type { Mutator } from "./data/mutations";
import type { Env } from "./env";

export interface Deps {
  /** Sign in with Apple signing keys; tests pass a local key set. */
  appleKeys: JWTVerifyGetKey;
  /** The in-app assistant's model provider, built from the Worker's vars and secrets; tests pass a fake. */
  ai: (env: Env) => AiProvider;
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
