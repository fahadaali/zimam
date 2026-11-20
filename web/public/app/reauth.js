// The fresh sign-in that deleting the account asks for (settings-view.js), in popups as on the
// sign-in screen (main.js) and with the same pieces: a new random nonce whose SHA-256 the provider
// signs (lib/nonce.js), Apple's popup with the same redirect URI, and Google's popup returning
// through /app/google-callback (lib/google.js). What comes back is only the body for DELETE
// /v1/me (lib/reauth.js): it is never sent to /v1/auth, never stored, and the session stays as it
// was. Google's whole-tab sign-in is not offered here, since coming back would sign in.
import { googleAuthUrl, googleCallbackUrl, googleEnabled, googlePopupFeatures, googleState, googleStateMatches } from "./lib/google.js";
import { randomNonce, sha256Hex } from "./lib/nonce.js";
import { ReauthError, appleReauthBody, googleReauthBody } from "./lib/reauth.js";

/** `{ appleClientId, googleClientId }` as in main.js. */
export function createReauth({ appleClientId, googleClientId }) {
  /** Nonces ready before the click, since the popups must open inside it. */
  const next = { apple: null, google: null };
  /** The Google popup waiting for its answer: { state, raw, resolve, reject }. */
  let waiting = null;

  const fresh = async () => {
    const raw = randomNonce();
    return { raw, hashed: await sha256Hex(raw), random: randomNonce(16) };
  };

  /** Readies a nonce for each provider; call when the buttons are shown. */
  async function prepare() {
    [next.apple, next.google] = await Promise.all([fresh(), googleEnabled(googleClientId) ? fresh() : null]);
  }

  /** Sign in with Apple in its popup; resolves to the DELETE body. Call inside the click. */
  function apple() {
    const auth = window.AppleID?.auth;
    const attempt = next.apple;
    if (!auth || !attempt) return Promise.reject(new ReauthError("unavailable"));
    next.apple = null;
    fresh().then((n) => (next.apple ??= n));
    // The same redirect URI as the sign-in screen, so the API can exchange Apple's code with it.
    const redirectUri = `${location.origin}/app`;
    let pending;
    try {
      auth.init({ clientId: appleClientId, scope: "", redirectURI: redirectUri, state: attempt.random, nonce: attempt.hashed, usePopup: true });
      pending = auth.signIn();
    } catch {
      return Promise.reject(new ReauthError("failed"));
    }
    return Promise.resolve(pending).then(
      (result) => {
        const identityToken = result?.authorization?.id_token;
        if (!identityToken || result.authorization.state !== attempt.random) throw new ReauthError("failed");
        return appleReauthBody({ identityToken, nonce: attempt.raw, authorizationCode: result.authorization.code, redirectUri });
      },
      (error) => {
        const cancelled = error?.error === "popup_closed_by_user" || error?.error === "user_cancelled_authorize";
        throw new ReauthError(cancelled ? "cancelled" : "failed");
      },
    );
  }

  /**
   * Google's sign-in in a popup; resolves to the DELETE body when the answer comes back (receive).
   * A popup closed without answering leaves the promise waiting, and the next attempt replaces it.
   */
  function google() {
    const attempt = next.google;
    if (!googleEnabled(googleClientId) || !attempt) return Promise.reject(new ReauthError("unavailable"));
    next.google = null;
    fresh().then((n) => (next.google ??= n));
    const state = googleState("popup", attempt.random);
    const url = googleAuthUrl({ clientId: googleClientId, redirectUri: googleCallbackUrl(location.origin), nonce: attempt.hashed, state });
    const popup = window.open(url, "zimam-google-reauth", googlePopupFeatures());
    if (!popup) return Promise.reject(new ReauthError("popup_blocked"));
    waiting?.reject(new ReauthError("cancelled"));
    return new Promise((resolve, reject) => {
      waiting = { state, raw: attempt.raw, resolve, reject };
    });
  }

  /**
   * Google's answer from the callback page (main.js hears it on the channel and from postMessage):
   * true when it belonged to the attempt waiting here, so the sign-in screen does not take it.
   */
  function receive(answer) {
    const attempt = waiting;
    if (!attempt || !googleStateMatches(attempt.state, answer?.state)) return false;
    waiting = null;
    if (answer.error) attempt.reject(new ReauthError(answer.error === "access_denied" ? "cancelled" : "failed"));
    else attempt.resolve(googleReauthBody({ idToken: answer.idToken, nonce: attempt.raw }));
    return true;
  }

  /** Drops a waiting attempt (the sheet closed, or the account left this tab). */
  function cancel() {
    waiting?.reject(new ReauthError("cancelled"));
    waiting = null;
  }

  return {
    prepare,
    signIn: (provider) => (provider === "google" ? google() : apple()),
    receive,
    cancel,
    googleEnabled: () => googleEnabled(googleClientId),
  };
}
