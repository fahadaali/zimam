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

/**
 * The consent page: which app asks, where access goes, and what it may do. Allowing opens
 * Sign in with Apple in a popup, so the grant is tied to the Zimam account that signed in.
 */
export function consentPage(details: ConsentDescription, handle: string, appleNonce: string, env: { MCP_ORIGIN: string; APPLE_WEB_CLIENT_ID: string }): string {
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
  <fieldset>
    <label><input type="checkbox" checked disabled> الاطلاع على المهام والمشاريع وجدول اليوم</label>
    <input type="hidden" name="scope" value="${SCOPES.read}">
    <label><input type="checkbox" name="scope" value="${SCOPES.write}"${wantsWrite ? " checked" : ""}> إضافة المهام وتعديلها وإنجازها</label>
  </fieldset>
  <p class="muted callout">للسماح سجّل الدخول بحساب أبل الذي تستعمله في تطبيق زمام.</p>
  <p class="warning callout" id="error" role="alert">تعذّر تسجيل الدخول بحساب أبل. حاول مرة أخرى.</p>
  <div class="actions">
    <button type="button" class="primary callout" id="allow">السماح وتسجيل الدخول بحساب أبل</button>
    <button type="submit" class="secondary callout">رفض</button>
  </div>
</form>`;

  const script = `
<script src="https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/ar_SA/appleid.auth.js"></script>
<script>
  AppleID.auth.init({
    clientId: ${scriptValue(env.APPLE_WEB_CLIENT_ID)},
    scope: "",
    redirectURI: ${scriptValue(`${env.MCP_ORIGIN}/authorize`)},
    nonce: ${scriptValue(appleNonce)},
    usePopup: true
  });
  const form = document.getElementById("consent");
  document.getElementById("allow").addEventListener("click", async () => {
    document.getElementById("error").style.display = "none";
    try {
      const result = await AppleID.auth.signIn();
      form.elements.id_token.value = result.authorization.id_token;
      form.elements.decision.value = "approve";
      form.submit();
    } catch (error) {
      if (error && error.error === "popup_closed_by_user") return;
      document.getElementById("error").style.display = "block";
    }
  });
</script>`;

  return page(`ربط ${details.clientName} بزمام`, body, script);
}

export function messagePage(title: string, message: string): string {
  return page(title, `<h1 class="title">${escape(title)}</h1><p>${escape(message)}</p>`);
}

export function homePage(origin: string): string {
  return page(
    "خادم زمام لكلود وChatGPT",
    `<h1 class="title">خادم زمام لكلود وChatGPT</h1>
<p>أضف هذا الرابط موصلاً مخصصاً في كلود أو ChatGPT، ثم سجّل الدخول بحساب أبل الذي تستعمله في زمام:</p>
<p dir="ltr"><strong>${escape(`${origin}/mcp`)}</strong></p>`,
  );
}
