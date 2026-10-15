import { type Context, Hono } from "hono";
import { fail, readJson } from "../http";
import { activeJob, failJob, type ImportDeps, importsFromEnv, insertJob } from "../imports/jobs";
import {
  callbackUrl,
  exchangeCode,
  isOAuthSource,
  oauthAvailable,
  parseReturnTarget,
  returnUrl,
  type StateRow,
  startAuthorization,
  takeState,
  trelloToken,
} from "../imports/oauth";
import { hasProAccess, requirePro } from "../subscriptions/entitlements";
import type { AppEnv } from "../types";

/**
 * Imports through OAuth (src/imports/oauth.ts), under /v1/imports/oauth. `start` is signed in;
 * the callbacks are public (app.ts lets them through): the single-use state names the user.
 */
export const importOAuth = new Hono<AppEnv>();

const deps = (c: Context<AppEnv>): ImportDeps => c.var.deps.imports?.(c.env) ?? importsFromEnv(c.env);

/** Paths `requireUser` skips: the providers come back here without a Zimam session. */
export const isOAuthCallback = (path: string) => /^\/v1\/imports\/oauth\/[a-z-]+\/callback$/.test(path);

/**
 * GET /v1/imports/oauth/:source/start?return=app|<site origin> — `{ url, expiresAt }`: the
 * provider's page to open (ASWebAuthenticationSession in the app, the same tab on the site).
 * 400 `invalid_source` or `invalid_return`, 403 `pro_required`, 409 `import_in_progress`,
 * 503 `source_unavailable` (the source's secrets are not set).
 */
importOAuth.get("/:source/start", requirePro, async (c) => {
  const source = c.req.param("source");
  if (!isOAuthSource(source)) return fail(c, 400, "invalid_source", "Unknown OAuth import source");
  if (!oauthAvailable(c.env, source)) return fail(c, 503, "source_unavailable", "This source is not set up on the server");
  const returnTo = parseReturnTarget(c.req.query("return"), c.env.ALLOWED_ORIGINS);
  if (!returnTo) return fail(c, 400, "invalid_return", 'return must be "app" or an allowed site origin');
  if (await activeJob(c.env.DB, c.var.userId)) return fail(c, 409, "import_in_progress", "Another import is still running");
  const started = await startAuthorization(c.env.DB, c.env, {
    userId: c.var.userId,
    source,
    returnTo,
    callback: callbackUrl(c.req.url, source),
  });
  return c.json(started);
});

/**
 * GET /v1/imports/oauth/:source/callback?code&state — the provider returns here. Exchanges the
 * code, queues the import with the token, and redirects to the client with `job` or `error`
 * (`denied`, `provider_error`, `exchange_failed`, `pro_required`, `import_in_progress`,
 * `import_unavailable`). A state that is unknown, used or expired gets an Arabic page instead:
 * there is nowhere known to return to.
 *
 * Trello returns its token in the URL fragment, which never reaches a server: for Trello this
 * answers a page whose script posts the fragment's token to the POST below.
 */
importOAuth.get("/:source/callback", async (c) => {
  const source = c.req.param("source");
  if (!isOAuthSource(source)) return page(c, 404, PAGE.unknown);
  if (source === "trello") return trelloPage(c);
  const state = c.req.query("state") ?? "";
  const row = await takeState(c.env.DB, state, source);
  if (!row) return page(c, 400, PAGE.expired);
  const code = c.req.query("code");
  const error = c.req.query("error");
  if (error || !code) return redirect(c, returnUrl(row.return_to, { error: error === "access_denied" || !error ? "denied" : "provider_error" }));
  let token: string;
  try {
    token = await exchangeCode(c.env, deps(c).fetch, source, { code, state, callback: callbackUrl(c.req.url, source) });
  } catch (e) {
    // The message names the source and the HTTP status only, never the code.
    console.error(`import oauth: ${e instanceof Error ? e.message : "exchange failed"}`);
    return redirect(c, returnUrl(row.return_to, { error: "exchange_failed" }));
  }
  return redirect(c, await startJob(c, row, token));
});

/** POST /v1/imports/oauth/trello/callback `{ state, token }` from the callback page — `{ redirect }`, or 400 `{ error }`. */
importOAuth.post("/trello/callback", async (c) => {
  const body = (await readJson(c)) as { state?: unknown; token?: unknown } | undefined;
  const row = typeof body?.state === "string" ? await takeState(c.env.DB, body.state, "trello") : null;
  if (!row) return fail(c, 400, "expired", PAGE.expired);
  noStore(c);
  if (body?.token === null || body?.token === undefined || body.token === "") {
    return c.json({ redirect: returnUrl(row.return_to, { error: "denied" }) });
  }
  const credential = trelloToken(c.env, body.token);
  if (!credential) return c.json({ redirect: returnUrl(row.return_to, { error: "exchange_failed" }) });
  return c.json({ redirect: await startJob(c, row, credential) });
});

/** Queues the import for the state's user with the token in the first message, and says where to go next. */
async function startJob(c: Context<AppEnv>, row: StateRow, token: string): Promise<string> {
  const db = c.env.DB;
  if (!(await hasProAccess(c.env, row.user_id))) return returnUrl(row.return_to, { error: "pro_required" });
  if (await activeJob(db, row.user_id)) return returnUrl(row.return_to, { error: "import_in_progress" });
  const { enqueue, files } = deps(c);
  const id = crypto.randomUUID();
  await insertJob(db, { id, userId: row.user_id, source: row.source, fileName: null, fileSize: null, fileKey: null });
  try {
    await enqueue({ jobId: id, cursor: 0, token });
  } catch (error) {
    console.error(`import ${id}: enqueue failed: ${error instanceof Error ? error.name : "error"}`);
    await failJob(db, files, id, "unavailable", "تعذّر بدء الاستيراد الآن. أعد المحاولة بعد قليل.");
    return returnUrl(row.return_to, { error: "import_unavailable" });
  }
  return returnUrl(row.return_to, { job: id });
}

// MARK: Responses

/** The callback's URL carries a code or token: no caching, no referrer. */
function noStore(c: Context<AppEnv>) {
  c.header("Cache-Control", "no-store");
  c.header("Referrer-Policy", "no-referrer");
}

function redirect(c: Context<AppEnv>, url: string) {
  noStore(c);
  return c.redirect(url, 302);
}

const PAGE = {
  expired: "انتهت صلاحية طلب الربط أو استُعمل من قبل. ارجع إلى زمام وابدأ الاستيراد مرة أخرى.",
  unknown: "هذا المصدر غير معروف. ارجع إلى زمام وابدأ الاستيراد من صفحته.",
  working: "جارٍ إكمال الربط بـ Trello…",
  failed: "تعذّر إكمال الربط. تحقّق من الاتصال، ثم ارجع إلى زمام وابدأ الاستيراد مرة أخرى.",
};

const escape = (text: string) => text.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);

/**
 * A minimal Arabic page on the API's origin. No styles (the browser's own, in both themes), no
 * third-party anything; a script only on Trello's page, allowed by its nonce.
 */
function page(c: Context<AppEnv>, status: 200 | 400 | 404, message: string, script?: string) {
  const nonce = script ? btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16)))) : null;
  noStore(c);
  c.header(
    "Content-Security-Policy",
    `default-src 'none'; script-src ${nonce ? `'nonce-${nonce}'` : "'none'"}; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
  );
  c.header("X-Content-Type-Options", "nosniff");
  const html = `<!doctype html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>زمام: الاستيراد</title>
</head>
<body>
<main>
<h1>زمام</h1>
<p id="message" role="status">${escape(message)}</p>
</main>
${script && nonce ? `<script nonce="${nonce}">${script}</script>` : ""}
</body>
</html>`;
  return c.html(html, status);
}

/**
 * Trello's return page: reads the token from the fragment, removes it from the address bar,
 * and posts it with the state to this same path, then follows the answer.
 */
function trelloPage(c: Context<AppEnv>) {
  const script = `(() => {
  const state = new URLSearchParams(location.search).get("state") || "";
  const token = new URLSearchParams(location.hash.slice(1)).get("token");
  history.replaceState(null, "", location.pathname);
  const show = (text) => { document.getElementById("message").textContent = text; };
  fetch(location.pathname, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ state, token }) })
    .then((r) => r.json())
    .then((b) => { if (b && typeof b.redirect === "string") location.replace(b.redirect); else show(${JSON.stringify(PAGE.expired)}); })
    .catch(() => show(${JSON.stringify(PAGE.failed)}));
})();`;
  return page(c, 200, PAGE.working, script);
}
