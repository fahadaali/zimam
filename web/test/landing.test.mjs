import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";

const publicDir = new URL("../public/", import.meta.url);
const html = readFileSync(new URL("index.html", publicDir), "utf8");

test("every screenshot on the landing page exists, has its dark twin, and says what it shows", () => {
  const images = [...html.matchAll(/<img\b[^>]*>/g)].map(([tag]) => tag).filter((tag) => tag.includes("/images/screens/"));
  assert.ok(images.length >= 9, "the page shows the app's screens");
  for (const tag of images) {
    const src = /src="\/([^"]+)"/.exec(tag)[1];
    assert.ok(existsSync(new URL(src, publicDir)), `missing ${src}`);
    assert.ok(existsSync(new URL(src.replace("-light.webp", "-dark.webp"), publicDir)), `no dark version of ${src}`);
    assert.match(tag, /alt="[^"]{10,}"/, `${src} needs a description`);
    assert.match(tag, /width="\d+" height="\d+"/, `${src} needs its size`);
  }
  for (const [, src] of html.matchAll(/srcset="\/([^"]+)"/g)) assert.ok(existsSync(new URL(src, publicDir)), `missing ${src}`);
});

test("the landing page keeps the house rules", () => {
  assert.ok(!html.includes("·"), "no middle dot next to Arabic digits");
  assert.ok(!/style="/.test(html), "no inline styles under the CSP");
  // Kashida only in the hero title («بـ٢٠ د» keeps the digit off the letter, as the app writes it).
  const kashida = [...html.matchAll(/[^\s<>]*ـ[^\s<>]*/g)].map(([word]) => word).filter((word) => !/^بـ[٠-٩]/.test(word));
  assert.deepEqual(kashida, ["يومـك"]);
});
