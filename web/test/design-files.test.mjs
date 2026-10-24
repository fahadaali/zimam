import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { copies } from "../scripts/copy-design.mjs";

const publicDir = fileURLToPath(new URL("../public", import.meta.url));

/** The site's own files (not the generated public/design/), with the paths under /design/ they name. */
async function references(dir = publicDir) {
  const found = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (path !== join(publicDir, "design")) found.push(...(await references(path)));
    } else if (/\.(html|css|js)$/.test(entry.name) || entry.name === "_headers") {
      for (const [, ref] of (await readFile(path, "utf8")).matchAll(/\/design\/([A-Za-z0-9_.\/-]+\.[a-z0-9]+)/g)) found.push({ file: path, ref });
    }
  }
  return found;
}

test("every /design/ file a page names is one copy-design.mjs deploys", async () => {
  const found = await references();
  assert.ok(found.length > 0);
  for (const { file, ref } of found) assert.ok(copies(ref), `${file} names /design/${ref}, which npm run build does not copy`);
});

test("only the files the pages use are deployed", () => {
  assert.equal(copies("components/bundle.js"), false);
  assert.equal(copies("logos/zimam-mark.svg"), false);
  assert.equal(copies("app-icons/app-icon-1024.png"), false);
  assert.equal(copies("fonts/web/thmanyahsans-Bold.woff2"), true);
});
