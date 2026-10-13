// Small enhancements for the landing page; it reads fully without them.
import { dualDate, localIsoDate } from "/app/lib/dates.js";

// Show today's date in both calendars in the Hijri example.
const sample = document.getElementById("sample-date");
if (sample) {
  try {
    sample.textContent = dualDate(localIsoDate());
  } catch {
    /* keep the static example */
  }
}

// «نسخ الرابط» appears only where the clipboard is available.
const copy = document.getElementById("copy-mcp");
const status = document.getElementById("copy-status");
const url = document.getElementById("mcp-url");
if (copy && url && navigator.clipboard?.writeText) {
  copy.hidden = false;
  copy.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(url.textContent.trim());
      status.textContent = "نُسخ الرابط.";
    } catch {
      status.textContent = "تعذّر النسخ. حدّد الرابط وانسخه يدوياً.";
    }
  });
}
