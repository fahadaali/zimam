import assert from "node:assert/strict";
import { test } from "node:test";
import { durationPhrase, prayerPhrase } from "../public/app/lib/prayer.js";

test("after a prayer by minutes", () => {
  assert.equal(prayerPhrase("asr", 20), "بعد العصر بـ٢٠ د");
  assert.equal(prayerPhrase("fajr", 5), "بعد الفجر بـ٥ د");
});

test("before a prayer is a negative offset", () => {
  assert.equal(prayerPhrase("maghrib", -10), "قبل المغرب بـ١٠ د");
});

test("no offset reads «عند», as in the app", () => {
  assert.equal(prayerPhrase("isha", 0), "عند العشاء");
  assert.equal(prayerPhrase("dhuhr", null), "عند الظهر");
  assert.equal(prayerPhrase("dhuhr", undefined), "عند الظهر");
});

test("hours read naturally", () => {
  assert.equal(prayerPhrase("maghrib", 60), "بعد المغرب بساعة");
  assert.equal(prayerPhrase("fajr", -120), "قبل الفجر بساعتين");
  assert.equal(durationPhrase(180), "بـ٣ س");
  assert.equal(prayerPhrase("asr", 90), "بعد العصر بـ٩٠ د");
});

test("no prayer, no phrase; never a middle dot", () => {
  assert.equal(prayerPhrase(null, 20), null);
  assert.equal(prayerPhrase("noon", 20), null);
  assert.ok(!prayerPhrase("asr", 20).includes("·"));
});
