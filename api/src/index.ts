import { providerFromEnv } from "./ai/provider";
import { createApp } from "./app";
import { appleKeys } from "./auth/apple";

export default createApp({ appleKeys, ai: (env) => providerFromEnv(env) });
export { ZimamService } from "./service";
