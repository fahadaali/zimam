import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";

const publicDir = new URL("../public/", import.meta.url);
const html = readFileSync(new URL("index.html", publicDir), "utf8");

test("every screenshot on the landing page exists in both themes, and says what it shows", () => {
  const images = [...html.matchAll(/<img\b[^>]*>/g)].map(([tag]) => tag).filter((tag) => tag.includes("/images/screens/"));
  const sources = images.map((tag) => /src="\/([^"]+)"/.exec(tag)[1]);
  assert.ok(sources.filter((src) => src.endsWith("-light.webp")).length >= 9, "the page shows the app's screens");
  for (const [i, tag] of images.entries()) {
    const src = sources[i];
    assert.ok(existsSync(new URL(src, publicDir)), `missing ${src}`);
    assert.match(tag, /alt="[^"]{10,}"/, `${src} needs a description`);
    assert.match(tag, /width="\d+" height="\d+"/, `${src} needs its size`);
    // Light and dark side by side, the page showing one by its theme; both lazy, so the hidden one never loads.
    const theme = src.endsWith("-dark.webp") ? "dark" : "light";
    assert.match(tag, new RegExp(`class="shot theme-${theme}"`), `${src} needs theme-${theme}`);
    assert.match(tag, /loading="lazy"/, `${src} should load lazily`);
    const twin = theme === "light" ? src.replace("-light.webp", "-dark.webp") : src.replace("-dark.webp", "-light.webp");
    assert.ok(sources.includes(twin), `${src} has no ${theme === "light" ? "dark" : "light"} twin on the page`);
  }
});

test("the theme toggle is on the page and theme.js loads before it paints", () => {
  assert.match(html, /<script src="\/theme\.js"><\/script>/);
  assert.match(html, /data-theme-toggle/);
  assert.ok(existsSync(new URL("theme.js", publicDir)));
});

test("the landing page keeps the house rules", () => {
  assert.ok(!html.includes("·"), "no middle dot next to Arabic digits");
  assert.ok(!/style="/.test(html), "no inline styles under the CSP");
  // Kashida only in the hero title («بـ٢٠ د» keeps the digit off the letter, as the app writes it).
  const kashida = [...html.matchAll(/[^\s<>]*ـ[^\s<>]*/g)].map(([word]) => word).filter((word) => !/^بـ[٠-٩]/.test(word));
  assert.deepEqual(kashida, ["يومـك"]);
});
