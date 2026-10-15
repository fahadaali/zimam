import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { GOOGLE_BUTTON_MAX_WIDTH, googleButtonOptions, googleEnabled, googleInitOptions, whenGoogleLoaded } from "../public/app/lib/google.js";

test("the Google button shows only with a client ID", () => {
  assert.equal(googleEnabled(""), false);
  assert.equal(googleEnabled("   "), false);
  assert.equal(googleEnabled(undefined), false);
  assert.equal(googleEnabled("123.apps.googleusercontent.com"), true);
});

test("Google's button is Arabic, says «continue with», and fits its container", () => {
  const light = googleButtonOptions({ width: 320 });
  assert.equal(light.locale, "ar");
  assert.equal(light.text, "continue_with");
  assert.equal(light.size, "large");
  assert.equal(light.theme, "outline");
  assert.equal(light.width, 320);
  assert.equal(googleButtonOptions({ dark: true }).theme, "filled_black");
  assert.equal(googleButtonOptions({ width: 900 }).width, GOOGLE_BUTTON_MAX_WIDTH);
  assert.equal(googleButtonOptions({ width: 0 }).width, GOOGLE_BUTTON_MAX_WIDTH);
  assert.equal(googleButtonOptions({ width: 120 }).width, 200);
});

test("Google is set up in popup mode with the hashed nonce and never signs in by itself", () => {
  const callback = () => {};
  const options = googleInitOptions("client", "abc123", callback);
  assert.deepEqual(
    { client_id: options.client_id, nonce: options.nonce, ux_mode: options.ux_mode, auto_select: options.auto_select },
    { client_id: "client", nonce: "abc123", ux_mode: "popup", auto_select: false },
  );
  assert.equal(options.callback, callback);
});

test("waits for Google's script when it loads after the app", () => {
  const win = {};
  const seen = [];
  whenGoogleLoaded((id) => seen.push(id), win);
  assert.deepEqual(seen, []);
  win.google = { accounts: { id: "gis" } };
  win.onGoogleLibraryLoad();
  assert.deepEqual(seen, ["gis"]);
  whenGoogleLoaded((id) => seen.push(`again:${id}`), win);
  assert.deepEqual(seen, ["gis", "again:gis"]);
});

test("the app's CSP allows Google Identity Services", async () => {
  const headers = await readFile(new URL("../public/_headers", import.meta.url), "utf8");
  const csp = headers.split("/app/*")[1].match(/^\s*Content-Security-Policy: (.+)$/m)[1];
  const directive = (name) => csp.split(";").map((d) => d.trim()).find((d) => d.startsWith(`${name} `));
  assert.match(directive("script-src"), /https:\/\/accounts\.google\.com\/gsi\/client/);
  assert.match(directive("style-src"), /https:\/\/accounts\.google\.com\/gsi\/style/);
  assert.match(directive("frame-src"), /https:\/\/accounts\.google\.com(\s|$)/);
  assert.match(directive("connect-src"), /https:\/\/accounts\.google\.com(\s|$)/);
});
