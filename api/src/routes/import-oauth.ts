import { type Context, Hono } from "hono";
import { z } from "zod";
import { fail, readJson } from "../http";
import { activeJob, failJob, getUserJob, type ImportDeps, importsFromEnv, insertJob, jobOut } from "../imports/jobs";
import {
  callbackUrl,
  createPending,
  exchangeCode,
  findPending,
  isOAuthSource,
  oauthAvailable,
  PROVIDERS,
  parseReturnTarget,
  returnUrl,
  startAuthorization,
  takePending,
  takeState,
  trelloToken,
} from "../imports/oauth";
import { hasProAccess, PRO_REQUIRED, requirePro } from "../subscriptions/entitlements";
import type { AppEnv } from "../types";

/**
 * Imports through OAuth (src/imports/oauth.ts), under /v1/imports/oauth. `start` and `confirm` are
 * signed in; the callbacks are public (app.ts lets them through): the single-use state names the
 * user. A callback starts nothing: the import starts at `confirm`, from the client the user is
 * signed in to, and only for the user who started the flow.
 */
export const importOAuth = new Hono<AppEnv>();

const deps = (c: Context<AppEnv>): ImportDeps => c.var.deps.imports?.(c.env) ?? importsFromEnv(c.env);

/** Paths `requireUser` skips: the providers come back here without a Zimam session. */
export const isOAuthCallback = (path: string) => /^\/v1\/imports\/oauth\/[a-z-]+\/callback$/.test(path);

/** Longest authorization code the callback keeps; providers' codes are far shorter. */
const MAX_CODE_LENGTH = 2048;

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
 * GET /v1/imports/oauth/:source/callback?code&state — the provider returns here. Takes the state,
 * keeps the code in a pending record for the state's user (10 minutes, single use), and redirects
 * to the client with `pending` (`zimam://import-callback?pending=…`, `<site>/app/#/import?pending=…`),
 * or with `error` (`denied`, `provider_error`). Nothing is exchanged or queued here: the signed-in
 * client confirms first (POST /confirm below). A state that is unknown, used or expired gets an
 * Arabic page instead: there is nowhere known to return to.
 *
 * Trello returns its token in the URL fragment, which never reaches a server: for Trello this
 * answers a page whose script posts the state to the POST below and passes the token on to the
 * client in the fragment.
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
  if (code.length > MAX_CODE_LENGTH) return redirect(c, returnUrl(row.return_to, { error: "provider_error" }));
  const pending = await createPending(c.env.DB, row, { state, code });
  return redirect(c, returnUrl(row.return_to, { pending, source: row.source }));
});

/**
 * POST /v1/imports/oauth/trello/callback `{ state, granted }` from Trello's callback page —
 * `{ redirect, token? }`, or 400 `{ error }`. The token itself stays in the browser: when
 * `token` is "fragment", the page adds it to the redirect's fragment for the client's confirm.
 */
importOAuth.post("/trello/callback", async (c) => {
  const body = (await readJson(c)) as { state?: unknown; granted?: unknown } | undefined;
  const row = typeof body?.state === "string" ? await takeState(c.env.DB, body.state, "trello") : null;
  if (!row) return fail(c, 400, "expired", PAGE.expired);
  noStore(c);
  if (body?.granted !== true) return c.json({ redirect: returnUrl(row.return_to, { error: "denied" }) });
  const pending = await createPending(c.env.DB, row, { state: body.state as string, code: null });
  return c.json({ redirect: returnUrl(row.return_to, { pending, source: row.source }), token: "fragment" });
});

const ConfirmBody = z.object({
  pending: z.string().min(1).max(200),
  /** Trello only: the token its page passed to the client in the fragment. Never stored or logged. */
  token: z.string().max(500).optional(),
});

const CONFIRM = {
  notFound: "انتهت صلاحية الطلب أو لا يخص حسابك. ابدأ الاستيراد مرة أخرى من حسابك في زمام.",
  expired: "انتهت صلاحية طلب الاستيراد أو استُعمل من قبل. ابدأ الاستيراد مرة أخرى.",
  invalidToken: "لم يصل إذن Trello كاملاً. ابدأ الاستيراد مرة أخرى.",
  exchangeFailed: "تعذّر إكمال الربط بالمصدر. ابدأ الاستيراد مرة أخرى.",
};

/**
 * POST /v1/imports/oauth/confirm `{ pending, token? }` — signed in. Starts the import a returned
 * flow is waiting for, once the user has seen which account receives it: exchanges the code (or
 * takes Trello's token from the body), queues the job with the token in its first message only,
 * and answers 202 `{ job }`. The record is taken once.
 *
 * 404 `not_found` when there is no such record or it is another user's (the same answer, so it
 * says nothing about either), 410 `expired` once used or after 10 minutes, 400 `invalid` or
 * `invalid_token` (Trello), 403 `pro_required`, 409 `import_in_progress`, 502 `exchange_failed`,
 * 503 `import_unavailable`. Refusals before the record is taken (400, 403, 409) leave it for a retry.
 */
importOAuth.post("/confirm", async (c) => {
  noStore(c);
  const body = ConfirmBody.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "pending is required");
  const db = c.env.DB;
  const userId = c.var.userId;
  const found = await findPending(db, body.data.pending, userId);
  if (found.kind === "not_found") return fail(c, 404, "not_found", CONFIRM.notFound);
  if (found.kind === "gone") return fail(c, 410, "expired", CONFIRM.expired);
  const { row } = found;
  const provider = PROVIDERS[row.source];

  let token: string | null = null;
  if (provider.flow === "trello") {
    token = trelloToken(c.env, body.data.token);
    if (!token) return fail(c, 400, "invalid_token", CONFIRM.invalidToken);
  } else if (!row.code) {
    return fail(c, 410, "expired", CONFIRM.expired);
  }
  if (!(await hasProAccess(c.env, userId))) return fail(c, 403, PRO_REQUIRED.code, PRO_REQUIRED.message);
  if (await activeJob(db, userId)) return fail(c, 409, "import_in_progress", "Another import is still running");
  if (!(await takePending(db, row))) return fail(c, 410, "expired", CONFIRM.expired);

  if (!token) {
    try {
      token = await exchangeCode(c.env, deps(c).fetch, row.source, {
        code: row.code!,
        verifier: row.code_verifier,
        callback: callbackUrl(c.req.url, row.source),
      });
    } catch (e) {
      // The message names the source and the HTTP status only, never the code.
      console.error(`import oauth: ${e instanceof Error ? e.message : "exchange failed"}`);
      return fail(c, 502, "exchange_failed", CONFIRM.exchangeFailed);
    }
  }

  const { enqueue, files } = deps(c);
  const id = crypto.randomUUID();
  await insertJob(db, { id, userId, source: row.source, fileName: null, fileSize: null, fileKey: null });
  try {
    await enqueue({ jobId: id, cursor: 0, token });
  } catch (error) {
    console.error(`import ${id}: enqueue failed: ${error instanceof Error ? error.name : "error"}`);
    await failJob(db, files, id, "unavailable", "تعذّر بدء الاستيراد الآن. أعد المحاولة بعد قليل.");
    return fail(c, 503, "import_unavailable", "Could not start the import");
  }
  const job = await getUserJob(db, userId, id);
  return c.json({ job: jobOut(job!) }, 202);
});

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
 * Trello's return page: reads the token from the fragment and removes it from the address bar,
 * posts only the state (and whether a token came) to this same path, then follows the answer,
 * carrying the token on in the redirect's fragment: `zimam://import-callback?pending=…#token=…`
 * or `<site>/app/#/import?pending=…&token=…`. The token never reaches the server before the
 * client's confirm, and never travels in a query.
 */
export const TRELLO_PAGE_SCRIPT = `(() => {
  const state = new URLSearchParams(location.search).get("state") || "";
  const token = new URLSearchParams(location.hash.slice(1)).get("token");
  history.replaceState(null, "", location.pathname);
  const show = (text) => { document.getElementById("message").textContent = text; };
  fetch(location.pathname, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ state, granted: !!token }) })
    .then((r) => r.json())
    .then((b) => {
      if (!b || typeof b.redirect !== "string") return show(${JSON.stringify(PAGE.expired)});
      let next = b.redirect;
      if (b.token === "fragment" && token) next += (next.includes("#") ? "&" : "#") + "token=" + encodeURIComponent(token);
      location.replace(next);
    })
    .catch(() => show(${JSON.stringify(PAGE.failed)}));
})();`;

function trelloPage(c: Context<AppEnv>) {
  return page(c, 200, PAGE.working, TRELLO_PAGE_SCRIPT);
}
