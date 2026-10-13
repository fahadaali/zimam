// Sign in with Apple nonce: the browser keeps a random nonce, gives Apple its SHA-256 (hex), and
// sends the raw nonce with the identity token so the API can check the token was minted for this
// sign-in (api/src/auth/apple.ts compares sha256Hex(nonce) with the token's nonce claim).

/** A URL-safe random string from 32 random bytes. */
export function randomNonce(bytes = 32) {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...data)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Lowercase hex SHA-256 of a UTF-8 string. */
export async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
