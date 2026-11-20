import assert from "node:assert/strict";
import { test } from "node:test";
import { ApiError, errorText } from "../public/app/lib/api.js";
import {
  ReauthError,
  appleReauthBody,
  deleteAccountErrorText,
  googleReauthBody,
  reauthErrorText,
  reauthProviders,
} from "../public/app/lib/reauth.js";

test("the body for DELETE /v1/me has the fields of the sign-in it repeats", () => {
  assert.deepEqual(
    appleReauthBody({ identityToken: "apple.jwt", nonce: "raw", authorizationCode: "c1", redirectUri: "https://zimam.work/app" }),
    { provider: "apple", identityToken: "apple.jwt", nonce: "raw", authorizationCode: "c1", redirectUri: "https://zimam.work/app" },
  );
  // Apple's code only with the redirect URI it was asked with, as on the sign-in screen.
  assert.deepEqual(appleReauthBody({ identityToken: "apple.jwt", nonce: "raw" }), { provider: "apple", identityToken: "apple.jwt", nonce: "raw" });
  assert.deepEqual(appleReauthBody({ identityToken: "apple.jwt", nonce: "raw", authorizationCode: "c1" }), { provider: "apple", identityToken: "apple.jwt", nonce: "raw" });
  assert.deepEqual(googleReauthBody({ idToken: "google.jwt", nonce: "raw" }), { provider: "google", idToken: "google.jwt", nonce: "raw" });
  // No `device`: it is not a sign-in, and no session comes of it.
  assert.ok(!("device" in googleReauthBody({ idToken: "g", nonce: "n" })));
});

test("the providers offered are the linked ones when known, else both", () => {
  assert.deepEqual(reauthProviders({ id: "u1" }), ["apple", "google"]);
  assert.deepEqual(reauthProviders({ id: "u1" }, { google: false }), ["apple"]);
  assert.deepEqual(reauthProviders({ providers: ["google"] }), ["google"]);
  assert.deepEqual(reauthProviders({ providers: ["google", "apple"] }), ["apple", "google"], "Apple first, as on the sign-in screen");
  // Linked to Google only, but no Google client here: Apple is still offered rather than nothing.
  assert.deepEqual(reauthProviders({ providers: ["google"] }, { google: false }), ["apple"]);
  assert.deepEqual(reauthProviders({ providers: [] }), ["apple", "google"]);
  assert.deepEqual(reauthProviders(null), ["apple", "google"]);
});

test("a refused deletion says why in Arabic", () => {
  const required = new ApiError(403, "reauth_required", "", { code: "reauth_required" });
  const mismatch = new ApiError(403, "reauth_mismatch", "", { code: "reauth_mismatch" });
  assert.equal(deleteAccountErrorText(required), errorText(required));
  assert.match(deleteAccountErrorText(required), /سجّل الدخول مرة أخرى/);
  assert.equal(deleteAccountErrorText(mismatch), "الحساب الذي دخلت به ليس هذا الحساب. ادخل بحساب أبل أو قوقل الذي تستعمله في زمام.");
  assert.match(deleteAccountErrorText(new ApiError(0, "network", "")), /تعذّر الاتصال بالخادم/);
  assert.equal(deleteAccountErrorText(new ApiError(500, "internal", "")), "تعذّر حذف الحساب. حاول مرة أخرى.");
  for (const error of [required, mismatch]) assert.notEqual(error.status, 401, "a refusal is not the end of the session");
});

test("a sign-in that did not finish says what to do, and nothing when the person closed it", () => {
  assert.equal(reauthErrorText(new ReauthError("cancelled"), "apple"), null);
  assert.equal(reauthErrorText(new ReauthError("popup_blocked"), "google"), "اسمح بالنوافذ المنبثقة لهذا الموقع، ثم حاول مرة أخرى.");
  assert.match(reauthErrorText(new ReauthError("unavailable"), "apple"), /بحساب أبل/);
  assert.equal(reauthErrorText(new ReauthError("failed"), "google"), "تعذّر التحقق بحساب قوقل. حاول مرة أخرى.");
  assert.equal(reauthErrorText(new Error("x"), "apple"), "تعذّر التحقق بحساب أبل. حاول مرة أخرى.");
});
