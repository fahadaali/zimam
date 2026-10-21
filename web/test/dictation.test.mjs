import assert from "node:assert/strict";
import { test } from "node:test";
import { dictatedTitle, dictationErrorText, dictationPrefix, transcriptOf } from "../public/app/lib/dictation.js";

test("dictated words follow what was typed, after a space", () => {
  assert.equal(dictationPrefix(""), "");
  assert.equal(dictationPrefix("   "), "");
  assert.equal(dictationPrefix(" راجع العقد "), "راجع العقد ");
  assert.equal(dictatedTitle("راجع العقد ", "بعد المغرب"), "راجع العقد بعد المغرب");
  assert.equal(dictatedTitle("", " ذكرني أتصل بأمي "), "ذكرني أتصل بأمي");
  assert.equal(dictatedTitle("", ""), "");
});

test("the transcript joins each result's best guess", () => {
  const results = [[{ transcript: "ذكرني أراجع العقد" }, { transcript: "غيرها" }], [{ transcript: " بعد العصر " }], [{ transcript: "" }]];
  assert.equal(transcriptOf(results), "ذكرني أراجع العقد بعد العصر");
  assert.equal(transcriptOf([]), "");
  assert.equal(transcriptOf(undefined), "");
});

test("a blocked microphone says how to allow it; a cancel says nothing", () => {
  assert.match(dictationErrorText("not-allowed"), /اسمح بالميكروفون/);
  assert.match(dictationErrorText("service-not-allowed"), /اسمح بالميكروفون/);
  assert.equal(dictationErrorText("no-speech"), "تعذّر الإملاء. حاول مرة أخرى.");
  assert.equal(dictationErrorText("network"), "تعذّر الإملاء. حاول مرة أخرى.");
  assert.equal(dictationErrorText("aborted"), null);
});
