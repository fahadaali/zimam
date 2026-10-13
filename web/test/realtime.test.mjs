import assert from "node:assert/strict";
import { test } from "node:test";
import { backoffDelay, changedSeq, realtimeUrl } from "../public/app/lib/realtime.js";

test("reconnects back off from a second to a minute, with jitter", () => {
  const low = () => 0;
  const high = () => 0.999999;
  assert.equal(backoffDelay(1, low), 500);
  assert.equal(backoffDelay(1, high), 1000);
  assert.equal(backoffDelay(2, high), 2000);
  assert.equal(backoffDelay(4, high), 8000);
  assert.equal(backoffDelay(7, high), 60000);
  assert.equal(backoffDelay(50, high), 60000);
  assert.equal(backoffDelay(50, low), 30000);
  for (let attempt = 1; attempt < 12; attempt++) {
    const delay = backoffDelay(attempt);
    assert.ok(delay >= 500 && delay <= 60000, `${attempt}: ${delay}`);
  }
});

test("the socket URL is the API's, over wss, with the ticket", () => {
  assert.equal(
    realtimeUrl("https://api.zimam.app", "zt_a+b/c"),
    "wss://api.zimam.app/v1/realtime?ticket=zt_a%2Bb%2Fc",
  );
  assert.equal(realtimeUrl("http://localhost:8787", "zt_x"), "ws://localhost:8787/v1/realtime?ticket=zt_x");
});

test("only well-formed changed messages count", () => {
  assert.equal(changedSeq('{"type":"changed","seq":42}'), 42);
  assert.equal(changedSeq("pong"), null);
  assert.equal(changedSeq('{"type":"other","seq":1}'), null);
  assert.equal(changedSeq('{"type":"changed","seq":"1"}'), null);
  assert.equal(changedSeq("{not json"), null);
  assert.equal(changedSeq(new ArrayBuffer(2)), null);
});
