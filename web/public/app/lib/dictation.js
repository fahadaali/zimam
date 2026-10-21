// «إملاء» in the add sheet, as AddTaskView.swift: the words heard so far follow what was typed
// before listening began. Pure functions, no DOM; tested in test/dictation.test.mjs. The button and
// the browser's SpeechRecognition are in ../assistant-view.js.

/** What stays before the dictated words: the typed title and a space, or nothing. */
export function dictationPrefix(typed) {
  const text = (typed ?? "").trim();
  return text ? `${text} ` : "";
}

/** The title while dictating: the prefix, then the words heard so far. */
export function dictatedTitle(prefix, words) {
  return `${prefix}${(words ?? "").trim()}`;
}

/** The words of a SpeechRecognitionResultList (or arrays shaped like it): each result's best guess, joined. */
export function transcriptOf(results) {
  const parts = [];
  for (let i = 0; i < (results?.length ?? 0); i++) {
    const text = results[i]?.[0]?.transcript?.trim();
    if (text) parts.push(text);
  }
  return parts.join(" ");
}

/** Arabic text for a SpeechRecognitionErrorEvent's `error`; null for one that needs nothing said. */
export function dictationErrorText(code) {
  if (code === "aborted") return null;
  if (code === "not-allowed" || code === "service-not-allowed") return "تعذّر الاستماع. اسمح بالميكروفون لهذا الموقع ثم حاول مرة أخرى.";
  return "تعذّر الإملاء. حاول مرة أخرى.";
}
