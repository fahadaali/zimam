import { providerFromEnv } from "./ai/provider";
import { createApp } from "./app";
import { appleKeys } from "./auth/apple";
import { appleTokensFromEnv } from "./auth/apple-tokens";

export default createApp({ appleKeys, ai: (env) => providerFromEnv(env), appleTokens: (env) => appleTokensFromEnv(env) });
export { ZimamService } from "./service";
