import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  GOOGLE_AUTH_ENDPOINT,
  GOOGLE_MESSAGE_TYPE,
  googleAuthUrl,
  googleCallbackUrl,
  googleEnabled,
  googlePopupFeatures,
  googleState,
  googleStateMatches,
  googleStateMode,
  isGoogleMessage,
  parseGoogleFragment,
} from "../public/app/lib/google.js";

const ORIGIN = "https://zimam-web.fahad2ao.workers.dev";
const RANDOM = "abcdefghijklmnopqrstuv"; // randomNonce(16): 22 URL-safe characters

test("the Google button shows only with a client ID", () => {
  assert.equal(googleEnabled(""), false);
  assert.equal(googleEnabled("   "), false);
  assert.equal(googleEnabled(undefined), false);
  assert.equal(googleEnabled("123.apps.googleusercontent.com"), true);
});

test("Google returns to the callback page on this origin", () => {
  assert.equal(googleCallbackUrl(ORIGIN), `${ORIGIN}/app/google-callback`);
});

test("the sign-in URL asks Google's authorization endpoint for an ID token only, with our nonce and state", () => {
  const url = new URL(
    googleAuthUrl({
      clientId: "client.apps.googleusercontent.com",
      redirectUri: googleCallbackUrl(ORIGIN),
      nonce: "a".repeat(64),
      state: googleState("popup", RANDOM),
    }),
  );
  assert.equal(`${url.origin}${url.pathname}`, GOOGLE_AUTH_ENDPOINT);
  const params = Object.fromEntries(url.searchParams);
  assert.deepEqual(params, {
    client_id: "client.apps.googleusercontent.com",
    redirect_uri: `${ORIGIN}/app/google-callback`,
    response_type: "id_token",
    scope: "openid email profile",
    nonce: "a".repeat(64),
    state: `p.${RANDOM}`,
    prompt: "select_account",
    hl: "ar",
  });
});

test("state says whether the answer goes to a popup's opener or back to the app in the same tab", () => {
  assert.equal(googleState("popup", RANDOM), `p.${RANDOM}`);
  assert.equal(googleState("redirect", RANDOM), `r.${RANDOM}`);
  assert.equal(googleStateMode(`p.${RANDOM}`), "popup");
  assert.equal(googleStateMode(`r.${RANDOM}`), "redirect");
  assert.equal(googleStateMode("p.short"), null);
  assert.equal(googleStateMode(`x.${RANDOM}`), null);
  assert.equal(googleStateMode(`p.${RANDOM}<script>`), null);
  assert.equal(googleStateMode(undefined), null);
});

test("Google's answer is read from the URL fragment", () => {
  assert.deepEqual(parseGoogleFragment(`#state=p.${RANDOM}&id_token=eyJ.a.b&authuser=0&prompt=consent`), {
    idToken: "eyJ.a.b",
    state: `p.${RANDOM}`,
  });
  assert.deepEqual(parseGoogleFragment(`#error=access_denied&state=p.${RANDOM}`), {
    error: "access_denied",
    state: `p.${RANDOM}`,
  });
  assert.equal(parseGoogleFragment(""), null);
  assert.equal(parseGoogleFragment("#id_token=eyJ.a.b"), null, "no state, no answer");
  assert.equal(parseGoogleFragment(`#state=p.${RANDOM}`), null, "no token, no answer");
  assert.equal(parseGoogleFragment(undefined), null);
});

test("only the attempt that asked accepts the answer", () => {
  const state = googleState("popup", RANDOM);
  assert.equal(googleStateMatches(state, state), true);
  assert.equal(googleStateMatches(state, googleState("popup", "zyxwvutsrqponmlkjihgfe")), false);
  assert.equal(googleStateMatches(state, googleState("redirect", RANDOM)), false);
  assert.equal(googleStateMatches(state, `${state}x`), false);
  assert.equal(googleStateMatches("", ""), false);
  assert.equal(googleStateMatches(null, state), false);
  assert.equal(googleStateMatches(state, undefined), false);
});

test("messages count only from this origin and with the callback's type", () => {
  const data = { type: GOOGLE_MESSAGE_TYPE, idToken: "t", state: "p.x" };
  assert.equal(isGoogleMessage(data, ORIGIN, ORIGIN), true);
  assert.equal(isGoogleMessage(data, "https://evil.example", ORIGIN), false);
  assert.equal(isGoogleMessage({ ...data, type: "other" }, ORIGIN, ORIGIN), false);
  assert.equal(isGoogleMessage({ type: GOOGLE_MESSAGE_TYPE }, ORIGIN, ORIGIN), false);
  assert.equal(isGoogleMessage(null, ORIGIN, ORIGIN), false);
});

test("the popup is centred on the current window", () => {
  const features = googlePopupFeatures({ screenX: 100, screenY: 50, outerWidth: 1300, outerHeight: 900 });
  assert.equal(features, "popup=yes,width=500,height=640,left=500,top=180");
  assert.match(googlePopupFeatures({}), /^popup=yes,width=500,height=640,left=0,top=0$/);
});

/** The CSP directives for a path rule in _headers. */
async function cspFor(rule) {
  const headers = await readFile(new URL("../public/_headers", import.meta.url), "utf8");
  const block = headers.split(/\n(?=\/)/).find((b) => b.startsWith(`${rule}\n`));
  assert.ok(block, `no ${rule} rule`);
  const csp = block.match(/^\s*Content-Security-Policy: (.+)$/m)[1];
  return (name) => csp.split(";").map((d) => d.trim()).find((d) => d === name || d.startsWith(`${name} `));
}

test("the app's CSP no longer lets anything from Google into the page", async () => {
  const directive = await cspFor("/app/*");
  for (const name of ["script-src", "style-src", "frame-src", "connect-src", "img-src"]) {
    assert.doesNotMatch(directive(name) ?? "", /google/, name);
  }
  assert.equal(directive("script-src"), "script-src 'self' https://appleid.cdn-apple.com");
  assert.equal(directive("style-src"), "style-src 'self'");
});

test("the callback page runs only its own script and sends nothing anywhere", async () => {
  const directive = await cspFor("/app/google-callback");
  assert.equal(directive("default-src"), "default-src 'none'");
  assert.equal(directive("script-src"), "script-src 'self'");
  assert.equal(directive("connect-src"), "connect-src 'none'");
  assert.equal(directive("frame-ancestors"), "frame-ancestors 'none'");
});

test("no page loads Google's script, and the callback page has no inline script", async () => {
  const app = await readFile(new URL("../public/app/index.html", import.meta.url), "utf8");
  assert.doesNotMatch(app, /accounts\.google\.com/);
  const callback = await readFile(new URL("../public/app/google-callback.html", import.meta.url), "utf8");
  const scripts = [...callback.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)];
  assert.equal(scripts.length, 1);
  assert.match(scripts[0][1], /src="\/app\/google-callback\.js"/);
  assert.equal(scripts[0][2].trim(), "");
});
