// Google's sign-in comes back here (/app/google-callback#id_token=…&state=…). From a popup, the
// answer goes to the page that opened it, over a same-origin BroadcastChannel (the opener link
// may be cut on the way through Google's pages) and by postMessage to the opener when it is
// still there, then the popup closes. When the whole tab went to Google (popup blocked), the
// answer waits in session storage and the tab returns to /app/, which finishes the sign-in.
// The token never stays in the address bar. main.js checks `state` in both cases.
import {
  GOOGLE_CHANNEL,
  GOOGLE_MESSAGE_TYPE,
  GOOGLE_RESULT_KEY,
  googleStateMode,
  parseGoogleFragment,
} from "./lib/google.js";

const answer = parseGoogleFragment(location.hash);
history.replaceState(null, "", location.pathname);

const status = document.getElementById("google-status");
const back = document.getElementById("google-back");

function finish(text) {
  status.textContent = text;
  back.hidden = false;
}

if (!answer) {
  finish("لم يصل رد من قوقل. ارجع إلى زمام وحاول مرة أخرى.");
} else if (googleStateMode(answer.state) === "redirect") {
  try {
    sessionStorage.setItem(GOOGLE_RESULT_KEY, JSON.stringify(answer));
    location.replace("/app/");
  } catch {
    finish("تعذّر إكمال الدخول بحساب قوقل. ارجع إلى زمام وحاول مرة أخرى.");
  }
} else {
  const message = { type: GOOGLE_MESSAGE_TYPE, ...answer };
  try {
    const channel = new BroadcastChannel(GOOGLE_CHANNEL);
    channel.postMessage(message);
    channel.close();
  } catch {
    /* the opener below may still be reachable */
  }
  try {
    window.opener?.postMessage(message, location.origin);
  } catch {
    /* cut by the browser; the channel above carried it */
  }
  window.close();
  // Still open (the browser did not let the page close itself): say where to go.
  finish("أُرسل الرد إلى زمام. يمكنك إغلاق هذه النافذة.");
}
