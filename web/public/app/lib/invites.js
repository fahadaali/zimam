// Project invites: reading the code from a link or pasted text, the links the join page offers,
// and the Arabic text for the API's answers. Pure functions, no DOM; tested in test/invites.test.mjs.
//
// The shared link is https://<site>/join/#<code>: the code rides in the fragment, so it never
// reaches a server log or a Referer header, and the static page web/public/join/ reads it here.
// Older forms are still read: /join/<code> (the API's link before), ?code=, and the
// app's zimam://join/<code>. apple/ZimamKit/Sources/ZimamKit/Sharing.swift (InviteCode) reads
// them by the same rules.

/** The app's URL scheme; «فتح في التطبيق» uses it because Safari keeps same-site universal links in the browser. */
export const APP_SCHEME = "zimam";
/** sessionStorage key for an invite waiting for sign-in in the web app. */
export const PENDING_JOIN_KEY = "zimam.pendingJoin";

const CODE = /^[A-Za-z0-9_-]{8,128}$/;

/** Whether `text` is an invite code (base64url, 8 to 128 characters). */
export function isInviteCode(text) {
  return typeof text === "string" && CODE.test(text);
}

/** The code in what the user pasted or opened: the code itself, any link form, or a message ending with the code. */
export function extractInviteCode(text) {
  if (typeof text !== "string") return null;
  const trimmed = text.trim();
  const at = trimmed.indexOf("/join");
  if (at !== -1) return fromLink(trimmed.slice(at + "/join".length));
  if (isInviteCode(trimmed)) return trimmed;
  // «…والصق هذا الرمز: <code>»: the last word of a pasted message.
  const last = trimmed.split(/\s+/).pop();
  return isInviteCode(last) ? last : null;
}

/** What follows /join: /<code>, /#<code>, #<code> or /?code=<code>, then anything after the code is dropped. */
function fromLink(tail) {
  let rest = tail.replace(/^[/#?]+/, "");
  if (rest.startsWith("code=")) rest = rest.slice("code=".length);
  const end = rest.search(/[?#/&\s]/);
  if (end !== -1) rest = rest.slice(0, end);
  return isInviteCode(rest) ? rest : null;
}

/**
 * The code on the join page, from its location: the fragment (#<code>), then ?code=, then a
 * path /join/<code> (reached through the 404 page, see join/redirect.js).
 */
export function codeFromJoinLocation({ pathname = "", search = "", hash = "" } = {}) {
  const fromHash = hash.replace(/^#/, "");
  let fragment = fromHash;
  try {
    fragment = decodeURIComponent(fromHash);
  } catch {
    /* keep it as it came */
  }
  if (isInviteCode(fragment)) return fragment;
  const fromHashParam = new URLSearchParams(fromHash).get("code");
  if (isInviteCode(fromHashParam)) return fromHashParam;
  const fromQuery = new URLSearchParams(search).get("code");
  if (isInviteCode(fromQuery)) return fromQuery;
  return extractInviteCode(pathname);
}

/** A /join/<code> path that the static site cannot serve: where the 404 page sends it instead. */
export function legacyJoinRedirect(pathname) {
  if (!/^\/join\/[^/]/.test(pathname ?? "")) return null;
  const code = extractInviteCode(pathname);
  return code ? `/join/#${code}` : null;
}

/** The web app's route for an invite. */
export function appJoinHash(code) {
  return `#/join/${encodeURIComponent(code)}`;
}

/** The web app with the invite open. */
export function webJoinUrl(code) {
  return `/app/${appJoinHash(code)}`;
}

/** The Apple app with the invite open (App/InviteLinks.swift). */
export function appSchemeUrl(code) {
  return `${APP_SCHEME}://join/${encodeURIComponent(code)}`;
}

/** The shareable link for an invite on a given site origin. */
export function inviteLink(origin, code) {
  return `${origin}/join/#${code}`;
}

const ROLE_NAMES = { owner: "المالك", editor: "محرر", viewer: "مشاهد" };
const ROLE_DESCRIPTIONS = { owner: "يدير المشروع وأعضاءه", editor: "يضيف المهام ويعدّلها", viewer: "يقرأ ويعلّق فقط" };

export function roleName(role) {
  return ROLE_NAMES[role] ?? "عضو";
}

export function roleDescription(role) {
  return ROLE_DESCRIPTIONS[role] ?? "";
}

const INVITE_ERRORS = {
  invite_expired: "انتهت صلاحية هذه الدعوة. اطلب دعوة جديدة من مالك المشروع.",
  invite_used: "استُعملت هذه الدعوة من قبل. اطلب دعوة جديدة من مالك المشروع.",
  invite_revoked: "ألغى المالك هذه الدعوة.",
  gone: "حُذف هذا المشروع.",
  not_found: "لم نجد هذه الدعوة. تحقّق من الرابط أو الرمز.",
  network: "تعذّر الاتصال بالخادم. تحقق من اتصالك ثم حاول مرة أخرى.",
};

/** The Arabic sentence for a failed preview or join, or null to fall back to the general message. */
export function inviteErrorText(code) {
  return INVITE_ERRORS[code] ?? null;
}
