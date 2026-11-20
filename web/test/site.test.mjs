// The site's own pages (not the web app): links that lead somewhere, the house rules, and what
// search engines and the CSP in _headers expect of them.
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";

const publicDir = new URL("../public/", import.meta.url);
const PAGES = ["index.html", "404.html", "privacy/index.html", "terms/index.html", "join/index.html"];
const read = (page) => readFileSync(new URL(page, publicDir), "utf8");

test("every site page is Arabic, right to left, titled, with one main heading", () => {
  for (const page of PAGES) {
    const html = read(page);
    assert.match(html, /<html lang="ar" dir="rtl"/, `${page}: lang and dir`);
    assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1/, `${page}: viewport`);
    assert.match(html, /<title>[^<]+<\/title>/, `${page}: title`);
    assert.equal([...html.matchAll(/<h1\b/g)].length, 1, `${page}: one h1`);
  }
});

test("every link and file a site page names exists, and every in-page link has its target", () => {
  for (const page of PAGES) {
    const html = read(page);
    const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map(([, id]) => id));
    for (const [, ref] of html.matchAll(/\s(?:href|src)="([^"]+)"/g)) {
      if (/^(https:|mailto:)/.test(ref)) continue;
      if (ref.startsWith("#")) {
        assert.ok(ids.has(ref.slice(1)), `${page}: no element for ${ref}`);
        continue;
      }
      assert.ok(ref.startsWith("/"), `${page}: ${ref} should be a root path (the 404 page is served at any depth)`);
      // /design/ is copied by npm run build; test/design-files.test.mjs checks those.
      if (ref.startsWith("/design/")) continue;
      let file = ref.split(/[?#]/)[0].slice(1);
      if (file === "" || file.endsWith("/")) file += "index.html";
      assert.ok(existsSync(new URL(file, publicDir)), `${page}: ${ref} does not exist`);
    }
  }
});

test("site pages keep to the CSP in _headers and the house rules", () => {
  for (const page of PAGES) {
    const html = read(page);
    assert.ok(!/<script(?![^>]*\ssrc=)[^>]*>/.test(html), `${page}: no inline script`);
    assert.ok(!/<style\b|\sstyle="|\son[a-z]+="/.test(html), `${page}: no inline style or handler`);
    const loaded = /<(?:script|img)\b[^>]*\ssrc="https?:|<link rel="(?:stylesheet|preload|modulepreload|icon|apple-touch-icon)"[^>]*\shref="https?:/;
    assert.ok(!loaded.test(html), `${page}: nothing loaded from another origin`);
    assert.ok(!html.includes("·"), `${page}: no middle dot next to Arabic digits`);
  }
});

test("the indexable pages name their canonical address; the invite page stays out of search", () => {
  const canonical = { "index.html": "https://zimam.work/", "privacy/index.html": "https://zimam.work/privacy/", "terms/index.html": "https://zimam.work/terms/" };
  for (const [page, url] of Object.entries(canonical)) assert.ok(read(page).includes(`<link rel="canonical" href="${url}">`), `${page}: canonical ${url}`);
  assert.match(read("join/index.html"), /<meta name="robots" content="noindex">/);
});

test("the policy and terms are dated in both calendars, Hijri first, with the Arabic comma", () => {
  for (const page of ["privacy/index.html", "terms/index.html"]) {
    assert.match(read(page), /آخر تحديث: [٠-٩]+ [^،<]+ [٠-٩]{4}هـ، [٠-٩]+ [^،<]+ [٠-٩]{4}\./, page);
  }
});

test("HSTS covers the subdomains and is ready for the preload list", () => {
  const headers = read("_headers");
  const hsts = headers.match(/^\s+Strict-Transport-Security: (.+)$/m)?.[1];
  assert.ok(hsts, "_headers sends Strict-Transport-Security");
  const maxAge = Number(hsts.match(/max-age=(\d+)/)?.[1]);
  assert.ok(maxAge >= 31536000, "max-age of a year or more, as the preload list requires");
  assert.match(hsts, /;\s*includeSubDomains\b/);
  assert.match(hsts, /;\s*preload\b/);
});
