import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest(async () => {
      const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
      return {
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            // Tests sign Google tokens for their own clients (test/helpers.ts), never the real ones.
            GOOGLE_CLIENT_IDS: "test-ios.apps.googleusercontent.com,test-web.apps.googleusercontent.com",
          },
        },
      };
    }),
  ],
  test: {
    setupFiles: ["./test/apply-migrations.ts"],
    // The Workers runtime cannot read Vitest 5's on-disk module cache.
    fsModuleCache: false,
  },
});
