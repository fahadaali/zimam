import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      // Tests pass a fake backend instead of the API service binding.
      miniflare: { serviceBindings: { API: () => new Response("not used in tests", { status: 500 }) } },
    }),
  ],
  test: {
    // The Workers runtime cannot read Vitest 5's on-disk module cache.
    fsModuleCache: false,
  },
});
