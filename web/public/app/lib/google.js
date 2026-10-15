// Sign in with Google through Google Identity Services (https://accounts.google.com/gsi/client).
// Google renders its own button (its branding rules ask for that); its callback gets an ID token
// whose nonce claim is the SHA-256 (hex) of a random nonce this page keeps, which the browser
// sends with the token to POST /v1/auth/google, as with Apple (lib/nonce.js).

/** Whether a client ID is set; without one the Google button stays hidden. */
export function googleEnabled(clientId) {
  return typeof clientId === "string" && clientId.trim() !== "";
}

/** The largest width Google draws its button at, in CSS pixels. */
export const GOOGLE_BUTTON_MAX_WIDTH = 400;

/** Options for google.accounts.id.renderButton: Arabic, «continue with», sized to its container. */
export function googleButtonOptions({ dark = false, width = GOOGLE_BUTTON_MAX_WIDTH } = {}) {
  return {
    type: "standard",
    theme: dark ? "filled_black" : "outline",
    size: "large",
    text: "continue_with",
    shape: "rectangular",
    logo_alignment: "center",
    locale: "ar",
    width: Math.max(200, Math.min(Math.floor(width) || GOOGLE_BUTTON_MAX_WIDTH, GOOGLE_BUTTON_MAX_WIDTH)),
  };
}

/** Options for google.accounts.id.initialize: popup mode, no automatic sign-in, our nonce. */
export function googleInitOptions(clientId, hashedNonce, callback) {
  return {
    client_id: clientId,
    nonce: hashedNonce,
    callback,
    ux_mode: "popup",
    context: "signin",
    auto_select: false,
    cancel_on_tap_outside: true,
  };
}

/** Runs `ready` with google.accounts.id once Google's script has loaded (it loads async). */
export function whenGoogleLoaded(ready, win = globalThis) {
  if (win.google?.accounts?.id) {
    ready(win.google.accounts.id);
    return;
  }
  const previous = win.onGoogleLibraryLoad;
  win.onGoogleLibraryLoad = () => {
    if (typeof previous === "function") previous();
    if (win.google?.accounts?.id) ready(win.google.accounts.id);
  };
}
