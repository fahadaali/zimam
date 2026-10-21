import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { ICON_PATHS } from "../public/app/lib/icons.js";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

test("every icon the markup and the scripts name exists", () => {
  const names = new Set();
  for (const [, name] of read("../public/app/index.html").matchAll(/data-icon="([^"]+)"/g)) names.add(name);
  for (const file of ["main.js", "shell.js", "task-pane.js", "assistant-view.js", "lib/components.js"]) {
    for (const [, name] of read(`../public/app/${file}`).matchAll(/\bicon(?:Name)?\(\s*"([^"]+)"/g)) names.add(name);
    for (const [, name] of read(`../public/app/${file}`).matchAll(/icon: "([^"]+)"/g)) names.add(name);
  }
  assert.ok(names.size > 10);
  for (const name of names) assert.ok(ICON_PATHS[name], `missing icon: ${name}`);
});
