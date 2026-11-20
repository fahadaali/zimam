import assert from "node:assert/strict";
import { test } from "node:test";
import { request, session, whenSignedOut } from "../public/app/lib/api.js";

// Node has no localStorage here, so every access throws, as in a browser that blocks storage.
test("with storage blocked, the session lasts for the page", () => {
  assert.equal(session.get(), null);
  session.set("token-1");
  assert.equal(session.get(), "token-1");
  session.clear();
  assert.equal(session.get(), null);
});

const unauthorized = () => new Response(JSON.stringify({ error: { code: "unauthorized", message: "no" } }), { status: 401 });

test("a 401 for the current session ends it", async (t) => {
  let ended = 0;
  whenSignedOut(() => ended++);
  t.mock.method(globalThis, "fetch", async () => unauthorized());
  session.set("old");
  await assert.rejects(request("GET", "/v1/me"), { status: 401 });
  assert.equal(session.get(), null);
  assert.equal(ended, 1);
});

test("a late 401 for a session already replaced leaves the new one", async (t) => {
  let ended = 0;
  whenSignedOut(() => ended++);
  let answer;
  t.mock.method(globalThis, "fetch", () => new Promise((resolve) => (answer = resolve)));
  session.set("old");
  const pending = request("GET", "/v1/me");
  session.set("new"); // signed out and back in while the request was on its way
  answer(unauthorized());
  await assert.rejects(pending, { status: 401 });
  assert.equal(session.get(), "new");
  assert.equal(ended, 0);
  session.clear();
});
