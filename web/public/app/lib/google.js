// Sign in with Google through Google's OAuth 2.0 authorization endpoint, with no Google script on
// the page: our own button opens Google's sign-in in a popup (or the whole tab when popups are
// blocked), Google returns an ID token in the URL fragment of /app/google-callback, and that page
// hands it back here (google-callback.js). The token's nonce claim is the SHA-256 (hex) of a random
// nonce this page keeps, which the browser sends with the token to POST /v1/auth/google, as with
// Apple (lib/nonce.js). `state` ties the answer to the click that asked for it.
//
// The callback URL must be listed under «Authorized redirect URIs» of the Google web client
// (docs/setup.md, «الدخول بحساب قوقل»).

export const GOOGLE_AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth";

/** Where Google returns, on this site's origin. */
export const GOOGLE_CALLBACK_PATH = "/app/google-callback";

/** The popup's answer travels on this channel (same origin only), and by postMessage to the opener. */
export const GOOGLE_CHANNEL = "zimam-google-signin";

/** Session storage: the attempt waiting for Google when the whole tab went (popup blocked)… */
export const GOOGLE_PENDING_KEY = "zimam.google.pending";
/** …and Google's answer, left by the callback page for /app/ to finish the sign-in. */
export const GOOGLE_RESULT_KEY = "zimam.google.result";

/** The type of the message the callback page sends. */
export const GOOGLE_MESSAGE_TYPE = "zimam:google";

/** Whether a client ID is set; without one the Google button stays hidden. */
export function googleEnabled(clientId) {
  return typeof clientId === "string" && clientId.trim() !== "";
}

/** The redirect URI for an origin, e.g. https://zimam-web.fahad2ao.workers.dev/app/google-callback. */
export function googleCallbackUrl(origin) {
  return `${origin}${GOOGLE_CALLBACK_PATH}`;
}

/**
 * `state` for one attempt: "p." (popup) or "r." (whole tab) and a random part, so the callback
 * page knows whether to answer an opener or to take the tab back to the app.
 */
export function googleState(mode, random) {
  return `${mode === "redirect" ? "r" : "p"}.${random}`;
}

/** "popup" or "redirect", from a state made by googleState; null for anything else. */
export function googleStateMode(state) {
  if (typeof state !== "string") return null;
  if (/^p\.[A-Za-z0-9_-]{16,}$/.test(state)) return "popup";
  if (/^r\.[A-Za-z0-9_-]{16,}$/.test(state)) return "redirect";
  return null;
}

/** Whether Google's answer belongs to the attempt that asked: both states present and equal. */
export function googleStateMatches(expected, received) {
  if (typeof expected !== "string" || typeof received !== "string") return false;
  if (expected === "" || expected.length !== received.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ received.charCodeAt(i);
  return diff === 0;
}

/**
 * The sign-in URL: an ID token only (no access to anything), for openid, email and profile,
 * with Google's account chooser in Arabic. `nonce` is the hashed nonce.
 */
export function googleAuthUrl({ clientId, redirectUri, nonce, state }) {
  const url = new URL(GOOGLE_AUTH_ENDPOINT);
  url.search = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "id_token",
    scope: "openid email profile",
    nonce,
    state,
    prompt: "select_account",
    hl: "ar",
  }).toString();
  return url.toString();
}

/**
 * Google's answer from the callback URL's fragment: { idToken, state } on success,
 * { error, state } when Google reports one (access_denied when the user cancels), or null
 * when the fragment is not an answer at all.
 */
export function parseGoogleFragment(hash) {
  const params = new URLSearchParams(String(hash ?? "").replace(/^#/, ""));
  const state = params.get("state") ?? "";
  const error = params.get("error");
  if (error) return { error, state };
  const idToken = params.get("id_token");
  if (!idToken || !state) return null;
  return { idToken, state };
}

/** Features for the popup: a window the size of Google's chooser, centred on the current one. */
export function googlePopupFeatures(win = globalThis) {
  const width = 500;
  const height = 640;
  const left = Math.max(0, Math.round((win.screenX ?? 0) + ((win.outerWidth ?? width) - width) / 2));
  const top = Math.max(0, Math.round((win.screenY ?? 0) + ((win.outerHeight ?? height) - height) / 2));
  return `popup=yes,width=${width},height=${height},left=${left},top=${top}`;
}

/** Whether a message is the callback page's answer: right type, same origin. */
export function isGoogleMessage(data, origin, expectedOrigin) {
  return origin === expectedOrigin && data?.type === GOOGLE_MESSAGE_TYPE && typeof data.state === "string";
}
