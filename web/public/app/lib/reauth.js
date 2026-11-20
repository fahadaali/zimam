// Deleting the account asks for a fresh sign-in first (api/DEVELOPMENT.md, «حذف الحساب»): DELETE
// /v1/me carries a new identity token from Apple or Google, with the same fields as POST
// /v1/auth/apple or /v1/auth/google, minted for a new nonce in the last ten minutes for an identity
// linked to this account. The token proves who is deleting; it never becomes a session. Pure
// functions, no DOM; tested in test/reauth.test.mjs. The popups are reauth.js's.
import { errorText } from "./api.js";

/** The providers the web can sign in with, in the order their buttons are shown. */
export const REAUTH_PROVIDERS = ["apple", "google"];

/**
 * Which providers to offer: those the account says it is linked to (`me.providers`, when the API
 * sends it), else both, since either may be linked. Google only with a client ID.
 */
export function reauthProviders(me, { google = true } = {}) {
  const offered = REAUTH_PROVIDERS.filter((p) => p !== "google" || google);
  const linked = Array.isArray(me?.providers) ? offered.filter((p) => me.providers.includes(p)) : [];
  return linked.length ? linked : offered;
}

/** DELETE /v1/me's body after Sign in with Apple: the code and its redirect URI only together. */
export function appleReauthBody({ identityToken, nonce, authorizationCode, redirectUri }) {
  const body = { provider: "apple", identityToken, nonce };
  if (authorizationCode && redirectUri) Object.assign(body, { authorizationCode, redirectUri });
  return body;
}

/** DELETE /v1/me's body after Sign in with Google. */
export function googleReauthBody({ idToken, nonce }) {
  return { provider: "google", idToken, nonce };
}

/** Why the fresh sign-in did not give a token: the person closed it, or it failed. */
export class ReauthError extends Error {
  /** "cancelled", "popup_blocked", "unavailable" or "failed". */
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

/** The sentence under «تأكيد هويتك» when the sign-in itself failed; null when there is nothing to say. */
export function reauthErrorText(error, provider) {
  const account = provider === "google" ? "قوقل" : "أبل";
  switch (error?.reason) {
    case "cancelled":
      return null;
    case "popup_blocked":
      return "اسمح بالنوافذ المنبثقة لهذا الموقع، ثم حاول مرة أخرى.";
    case "unavailable":
      return `تعذّر تحميل الدخول بحساب ${account}. تحقق من اتصالك ثم أعد تحميل الصفحة.`;
    default:
      return `تعذّر التحقق بحساب ${account}. حاول مرة أخرى.`;
  }
}

/** The sentence when DELETE /v1/me refused or failed (api.js MESSAGES has the reauth codes). */
export function deleteAccountErrorText(error) {
  if (["reauth_required", "reauth_mismatch", "invalid_token", "network"].includes(error?.code)) return errorText(error);
  return "تعذّر حذف الحساب. حاول مرة أخرى.";
}
