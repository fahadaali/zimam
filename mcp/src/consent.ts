import type { ConsentDescription } from "@cloudflare/workers-oauth-provider";
import { SCOPES } from "./env";

const escape = (value: string) => value.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);

/** A value for an inline <script>: JSON that cannot close the tag. */
const scriptValue = (value: unknown) => JSON.stringify(value).replace(/</g, "\\u003c");

function page(title: string, body: string, script = ""): string {
  return `<!doctype html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(title)}</title>
<link rel="icon" href="/app-icons/favicon.svg">
<link rel="stylesheet" href="/generated/tokens.css">
<style>
  body { margin: 0; min-block-size: 100vh; display: grid; place-items: center; background: var(--surface); color: var(--ink); }
  main { inline-size: min(100% - 2 * var(--space-4), 30rem); background: var(--surface-raised); border: 1px solid var(--line);
    border-radius: var(--radius-lg); padding: var(--space-6); margin-block: var(--space-6); }
  .mark { inline-size: var(--space-11); block-size: var(--space-11); display: block; margin-block-end: var(--space-4); }
  h1 { margin: 0 0 var(--space-3); }
  p { margin: 0 0 var(--space-3); }
  .muted { color: var(--ink-muted); }
  .warning { color: var(--priority-high); }
  fieldset { border: 0; padding: 0; margin: var(--space-4) 0; display: grid; gap: var(--space-2); }
  label { display: flex; gap: var(--space-2); align-items: center; min-block-size: var(--space-11); }
  input[type="checkbox"] { inline-size: var(--space-6); block-size: var(--space-6); accent-color: var(--brand); }
  .actions { display: flex; gap: var(--space-2); flex-wrap: wrap; margin-block-start: var(--space-4); }
  button { font: inherit; font-weight: 600; min-block-size: var(--space-11); padding-inline: var(--space-4);
    border-radius: var(--radius-md); border: 1px solid transparent; cursor: pointer; }
  button.primary { background: var(--brand); color: var(--on-brand); }
  button.secondary { background: var(--surface-raised); color: var(--ink); border-color: var(--line-strong); }
  button:focus-visible { outline: 2px solid var(--focus-ring); outline-offset: 2px; }
  #error { display: none; }
  /* Sign in with Apple and Google: our own buttons, the same size, corners and font. Their colours
     are Apple's and Google's (branding guidelines), not Zimam's, so they are written here. */
  .providers { display: flex; flex-direction: column; gap: var(--space-3); margin-block-start: var(--space-4);
    --apple-fill: #000000; --apple-ink: #ffffff; --google-fill: #ffffff; --google-ink: #1f1f1f; --google-stroke: #747775; }
  @media (prefers-color-scheme: dark) {
    .providers { --apple-fill: #ffffff; --apple-ink: #000000; --google-fill: #131314; --google-ink: #e3e3e3; --google-stroke: #8e918f; }
  }
  button.provider { display: flex; align-items: center; justify-content: center; gap: var(--space-3); inline-size: 100%;
    padding-block: var(--space-2); }
  button.apple { background: var(--apple-fill); color: var(--apple-ink); border-color: var(--apple-fill); }
  button.google { background: var(--google-fill); color: var(--google-ink); border-color: var(--google-stroke); }
  .provider svg { inline-size: calc(var(--space-6) - var(--space-1)); block-size: calc(var(--space-6) - var(--space-1)); flex: none; }
</style>
</head>
<body class="body">
<main>
<img class="mark" src="/logos/zimam-mark.svg" alt="">
${body}
</main>
${script}
</body>
</html>`;
}

/** Apple's logo, for the Sign in with Apple button. */
const APPLE_LOGO = `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path fill="currentColor" d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"/></svg>`;

/** Google's standard colour G, for the Sign in with Google button. */
const GOOGLE_LOGO = `<svg viewBox="0 0 48 48" aria-hidden="true" focusable="false"><path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/><path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/><path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/><path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>`;

export const GOOGLE_AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth";
/** Where Google's sign-in returns on this worker; listed in the Google web client's redirect URIs. */
export const GOOGLE_CALLBACK_PATH = "/google-callback";
/** Same-origin channel and message type the callback page answers the consent page on. */
const GOOGLE_CHANNEL = "zimam-google-signin";
const GOOGLE_MESSAGE_TYPE = "zimam:google";
/** Session storage: what the callback page needs to post the consent form after a whole-tab sign-in. */
const GOOGLE_PENDING_KEY = "zimam.google.consent";

/**
 * Google's sign-in URL without `state`, which the page adds per click: an ID token only, for
 * openid, email and profile, carrying `nonce` (the SHA-256 of the consent handle).
 */
export function googleAuthUrl(clientId: string, origin: string, nonce: string): string {
  const url = new URL(GOOGLE_AUTH_ENDPOINT);
  url.search = new URLSearchParams({
    client_id: clientId,
    redirect_uri: `${origin}${GOOGLE_CALLBACK_PATH}`,
    response_type: "id_token",
    scope: "openid email profile",
    nonce,
    prompt: "select_account",
    hl: "ar",
  }).toString();
  return url.toString();
}

/**
 * The consent page: which app asks, where access goes, and what it may do. Allowing opens
 * Sign in with Apple in a popup, or, when GOOGLE_WEB_CLIENT_ID is set, Google's sign-in page in a
 * popup (or the whole tab when popups are blocked), so the grant is tied to the Zimam account that
 * signed in. Both providers sign `nonce`, the SHA-256 of the consent handle.
 */
export function consentPage(
  details: ConsentDescription,
  handle: string,
  nonce: string,
  env: { MCP_ORIGIN: string; APPLE_WEB_CLIENT_ID: string; GOOGLE_WEB_CLIENT_ID?: string },
): string {
  const googleClientId = env.GOOGLE_WEB_CLIENT_ID?.trim() ?? "";
  const name = escape(details.clientName);
  const origin = details.clientDomain
    ? `<p class="muted callout">التطبيق منشور من <strong dir="ltr">${escape(details.clientDomain)}</strong>.</p>`
    : `<p class="muted callout">سجّل هذا التطبيق اسمه بنفسه، فاسمه غير موثّق.</p>`;
  const loopback = details.redirectIsLoopback
    ? `<p class="warning callout">سيُرسل الإذن إلى تطبيق على جهازك. تابع فقط إن كنت بدأت الربط منه الآن.</p>`
    : "";
  const wantsWrite = details.scope.length === 0 || details.scope.includes(SCOPES.write);

  const body = `
<h1 class="title">ربط ${name} بحسابك في زمام</h1>
<p>يطلب ${name} الوصول إلى مهامك ومشاريعك في زمام.</p>
${origin}
<p class="muted callout">سيُرسل الإذن إلى <strong dir="ltr">${escape(details.redirectHost)}</strong>.</p>
${loopback}
<form method="post" id="consent">
  <input type="hidden" name="handle" value="${escape(handle)}">
  <input type="hidden" name="decision" value="deny">
  <input type="hidden" name="id_token" value="">
  <input type="hidden" name="code" value="">
  <input type="hidden" name="provider" value="apple">
  <fieldset>
    <label><input type="checkbox" checked disabled> الاطلاع على المهام والمشاريع وجدول اليوم</label>
    <input type="hidden" name="scope" value="${SCOPES.read}">
    <label><input type="checkbox" name="scope" value="${SCOPES.write}"${wantsWrite ? " checked" : ""}> إضافة المهام وتعديلها وإنجازها</label>
  </fieldset>
  <p class="muted callout">للسماح سجّل الدخول بحساب ${googleClientId ? "أبل أو قوقل" : "أبل"} الذي تستعمله في تطبيق زمام.</p>
  <p class="warning callout" id="error" role="alert"></p>
  <div class="providers">
    <button type="button" class="provider apple headline" id="allow">${APPLE_LOGO}<span>المتابعة بحساب أبل</span></button>${
      googleClientId
        ? `
    <button type="button" class="provider google headline" id="google">${GOOGLE_LOGO}<span>المتابعة بحساب قوقل</span></button>`
        : ""
    }
  </div>
  <div class="actions">
    <button type="submit" class="secondary callout">رفض</button>
  </div>
</form>`;

  const script = `
<script src="https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/ar_SA/appleid.auth.js"></script>
<script>
  // Shared with Google's part below, so it is defined before anything that may throw.
  const form = document.getElementById("consent");
  const errorBox = document.getElementById("error");
  const showError = (text) => {
    errorBox.textContent = text;
    errorBox.style.display = "block";
  };
  const hideError = () => {
    errorBox.style.display = "none";
  };
  const approve = (provider, idToken, code) => {
    form.elements.provider.value = provider;
    form.elements.id_token.value = idToken;
    form.elements.code.value = code || "";
    form.elements.decision.value = "approve";
    form.submit();
  };
  AppleID.auth.init({
    clientId: ${scriptValue(env.APPLE_WEB_CLIENT_ID)},
    scope: "",
    redirectURI: ${scriptValue(`${env.MCP_ORIGIN}/authorize`)},
    nonce: ${scriptValue(nonce)},
    usePopup: true
  });
  document.getElementById("allow").addEventListener("click", async () => {
    hideError();
    try {
      const result = await AppleID.auth.signIn();
      // The code lets the API keep Apple's refresh token, revoked when the account is deleted.
      approve("apple", result.authorization.id_token, result.authorization.code);
    } catch (error) {
      if (error && (error.error === "popup_closed_by_user" || error.error === "user_cancelled_authorize")) return;
      showError("تعذّر تسجيل الدخول بحساب أبل. حاول مرة أخرى.");
    }
  });
</script>${googleClientId ? googleScript(googleAuthUrl(googleClientId, env.MCP_ORIGIN, nonce)) : ""}`;

  return page(`ربط ${details.clientName} بزمام`, body, script);
}

/**
 * Sign in with Google from our own button: Google's sign-in page in a popup, answering through
 * /google-callback with a `state` made for this click ("p." for a popup). When popups are blocked
 * the whole tab goes ("r."), after keeping the handle and the chosen scopes in session storage so
 * the callback page can post this form itself.
 */
function googleScript(authUrl: string): string {
  return `
<script>
  (() => {
    const button = document.getElementById("google");
    const failed = "تعذّر تسجيل الدخول بحساب قوقل. حاول مرة أخرى.";
    let waiting = null;
    const randomState = () => {
      const bytes = crypto.getRandomValues(new Uint8Array(16));
      return btoa(String.fromCharCode(...bytes)).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
    };
    const receive = (data) => {
      if (!data || data.type !== ${scriptValue(GOOGLE_MESSAGE_TYPE)} || !waiting || data.state !== waiting) return;
      waiting = null;
      if (data.error) {
        if (data.error !== "access_denied") showError(failed);
        return;
      }
      approve("google", data.idToken);
    };
    if ("BroadcastChannel" in window) {
      new BroadcastChannel(${scriptValue(GOOGLE_CHANNEL)}).addEventListener("message", (event) => receive(event.data));
    }
    window.addEventListener("message", (event) => {
      if (event.origin === location.origin) receive(event.data);
    });
    button.addEventListener("click", () => {
      hideError();
      const random = randomState();
      const url = new URL(${scriptValue(authUrl)});
      waiting = "p." + random;
      url.searchParams.set("state", waiting);
      const width = 500;
      const height = 640;
      const left = Math.max(0, Math.round(screenX + (outerWidth - width) / 2));
      const top = Math.max(0, Math.round(screenY + (outerHeight - height) / 2));
      const popup = window.open(url, "zimam-google", "popup=yes,width=" + width + ",height=" + height + ",left=" + left + ",top=" + top);
      if (popup) return;
      waiting = null;
      const state = "r." + random;
      const scopes = [...form.querySelectorAll('input[name="scope"]')]
        .filter((input) => input.type === "hidden" || input.checked)
        .map((input) => input.value);
      try {
        sessionStorage.setItem(${scriptValue(GOOGLE_PENDING_KEY)}, JSON.stringify({ state, handle: form.elements.handle.value, scopes }));
      } catch {
        showError("اسمح بالنوافذ المنبثقة لهذه الصفحة، ثم حاول مرة أخرى.");
        return;
      }
      url.searchParams.set("state", state);
      location.assign(url);
    });
  })();
</script>`;
}

/**
 * The page Google returns to (GET /google-callback), with the ID token in the URL fragment.
 * Its script is a separate file (GET /google-callback.js), so the page's CSP allows no inline
 * script.
 */
export function googleCallbackPage(): string {
  return page(
    "المتابعة بحساب قوقل",
    `<h1 class="title">المتابعة بحساب قوقل</h1>
<p class="callout" id="status" role="status">جارٍ إكمال الدخول بحساب قوقل…</p>`,
    `<script src="${GOOGLE_CALLBACK_PATH}.js"></script>`,
  );
}

/** The callback page's CSP: its own script only, no requests, no framing. */
export const GOOGLE_CALLBACK_CSP =
  "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; font-src 'self'; base-uri 'none'; frame-ancestors 'none'";

/**
 * The callback page's script. From a popup ("p." state) it hands Google's answer to the consent
 * page over a same-origin BroadcastChannel (the opener link may be cut on the way through
 * Google's pages) and by postMessage to the opener when it is still there, then closes. After a
 * whole-tab sign-in ("r." state) it checks the state against what the consent page kept, then
 * posts the consent form to /authorize itself. The token never stays in the address bar.
 */
export const GOOGLE_CALLBACK_SCRIPT = `(() => {
  const params = new URLSearchParams(location.hash.slice(1));
  history.replaceState(null, "", location.pathname);
  const state = params.get("state") || "";
  const error = params.get("error");
  const idToken = params.get("id_token");
  const status = document.getElementById("status");
  const say = (text) => { status.textContent = text; };

  if (!state || (!idToken && !error)) {
    say("لم يصل رد من قوقل. ارجع إلى صفحة الربط وحاول مرة أخرى.");
    return;
  }

  if (state.startsWith("r.")) {
    let pending = null;
    try {
      pending = JSON.parse(sessionStorage.getItem(${scriptValue(GOOGLE_PENDING_KEY)}) || "null");
      sessionStorage.removeItem(${scriptValue(GOOGLE_PENDING_KEY)});
    } catch {}
    if (!pending || pending.state !== state || error || !idToken) {
      say("لم يكتمل الدخول بحساب قوقل. ابدأ الربط من جديد من التطبيق.");
      return;
    }
    const form = document.createElement("form");
    form.method = "post";
    form.action = "/authorize";
    const add = (name, value) => {
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = name;
      input.value = value;
      form.append(input);
    };
    add("handle", String(pending.handle));
    add("decision", "approve");
    add("provider", "google");
    add("id_token", idToken);
    for (const scope of Array.isArray(pending.scopes) ? pending.scopes : []) add("scope", String(scope));
    document.body.append(form);
    say("جارٍ إكمال الربط…");
    form.submit();
    return;
  }

  const message = error
    ? { type: ${scriptValue(GOOGLE_MESSAGE_TYPE)}, error, state }
    : { type: ${scriptValue(GOOGLE_MESSAGE_TYPE)}, idToken, state };
  try {
    const channel = new BroadcastChannel(${scriptValue(GOOGLE_CHANNEL)});
    channel.postMessage(message);
    channel.close();
  } catch {}
  try {
    if (window.opener) window.opener.postMessage(message, location.origin);
  } catch {}
  window.close();
  say("أُرسل الرد إلى صفحة الربط. يمكنك إغلاق هذه النافذة.");
})();
`;

export function messagePage(title: string, message: string): string {
  return page(title, `<h1 class="title">${escape(title)}</h1><p>${escape(message)}</p>`);
}

export function homePage(origin: string): string {
  return page(
    "خادم زمام لكلود وChatGPT",
    `<h1 class="title">خادم زمام لكلود وChatGPT</h1>
<p>أضف هذا الرابط موصلاً مخصصاً في كلود أو ChatGPT، ثم سجّل الدخول بحساب أبل أو قوقل الذي تستعمله في زمام:</p>
<p dir="ltr"><strong>${escape(`${origin}/mcp`)}</strong></p>`,
  );
}
