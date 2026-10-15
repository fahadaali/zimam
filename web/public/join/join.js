// The invite page (/join/#<code>): reads the code from the fragment and offers the app or the web.
// The app opens through zimam://join/<code>: a tap on a universal link to this same site stays in
// Safari, so «فتح في التطبيق» cannot use the https link. Links shared from elsewhere
// (Messages, WhatsApp) open the app directly when it is installed (apple-app-site-association).
import { appSchemeUrl, codeFromJoinLocation, webJoinUrl } from "/app/lib/invites.js";

function show() {
  const code = codeFromJoinLocation(location);
  const box = document.getElementById("join-code");
  const actions = document.getElementById("join-actions");
  const missing = document.getElementById("join-missing");
  box.hidden = !code;
  actions.hidden = !code;
  missing.hidden = !!code;
  if (!code) return;
  document.getElementById("join-code-value").textContent = code;
  document.getElementById("open-app").href = appSchemeUrl(code);
  document.getElementById("open-web").href = webJoinUrl(code);
}

show();
// Pasting another invite link into the same tab changes only the fragment.
window.addEventListener("hashchange", show);
