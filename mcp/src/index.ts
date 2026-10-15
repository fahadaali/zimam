import OAuthProvider, {
  AuthorizationError,
  CimdFetchError,
  type OAuthResourceContext,
} from "@cloudflare/workers-oauth-provider";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import type { ZimamBackend } from "./backend";
import {
  GOOGLE_CALLBACK_CSP,
  GOOGLE_CALLBACK_PATH,
  GOOGLE_CALLBACK_SCRIPT,
  consentPage,
  googleCallbackPage,
  homePage,
  messagePage,
} from "./consent";
import { type Env, type GrantProps, SCOPES } from "./env";
import { buildServer } from "./tools";

const html = (body: string, status = 200, headers = new Headers()) => {
  headers.set("Content-Type", "text/html; charset=utf-8");
  return new Response(body, { status, headers });
};

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * GET shows the consent page; POST either declines, or verifies the Apple or Google
 * (`provider=google`) identity token from the page and completes the grant for that Zimam
 * user. The nonce either provider signs is the SHA-256 of the consent handle, so a token
 * only works for the page it was issued on.
 */
async function authorize(request: Request, env: Env, backend: ZimamBackend): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  try {
    if (request.method === "GET") {
      const authRequest = await oauth.parseAuthRequest(request);
      const details = await oauth.describeConsent(authRequest);
      const consent = await oauth.beginConsent(authRequest);
      return html(consentPage(details, consent.handle, await sha256Hex(consent.handle), env), 200, consent.headers);
    }
    if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });

    const form = await request.formData();
    const handle = String(form.get("handle") ?? "");
    if (form.get("decision") !== "approve") {
      const denied = await oauth.denyConsent(request, handle);
      return new Response(null, { status: 302, headers: denied.headers });
    }

    const idToken = String(form.get("id_token") ?? "");
    const google = form.get("provider") === "google";
    // Apple's code is exchanged with the redirect URI the consent page gave Sign in with Apple JS.
    const authorizationCode = String(form.get("code") ?? "").slice(0, 1000);
    const code = authorizationCode ? { authorizationCode, redirectUri: `${env.MCP_ORIGIN}/authorize` } : undefined;
    const signIn = google ? await backend.signInWithGoogle(idToken, handle) : await backend.signInWithApple(idToken, handle, code);
    if (!signIn.ok) {
      const account = google ? "قوقل" : "أبل";
      return html(messagePage("تعذّر تسجيل الدخول", `لم نتمكن من التحقق من حساب ${account}. ارجع إلى التطبيق وابدأ الربط من جديد.`), 401);
    }
    const scope = [...new Set([SCOPES.read, ...form.getAll("scope").map(String)])].filter((s) =>
      (Object.values(SCOPES) as string[]).includes(s),
    );
    const approved = await oauth.approveConsent(request, handle, { scope });
    const { redirectTo } = await oauth.completeAuthorization({
      request: approved.request,
      userId: signIn.value.userId,
      metadata: { name: signIn.value.name },
      scope: approved.request.scope,
      props: { userId: signIn.value.userId } satisfies GrantProps,
    });
    approved.headers.set("Location", redirectTo);
    return new Response(null, { status: 302, headers: approved.headers });
  } catch (error) {
    if (error instanceof AuthorizationError && error.redirectTo) return Response.redirect(error.redirectTo, 302);
    if (error instanceof AuthorizationError || error instanceof CimdFetchError) {
      return html(messagePage("تعذّر إكمال الربط", "انتهت صلاحية الصفحة أو أن الطلب غير صالح. ابدأ الربط من جديد من التطبيق."), 400);
    }
    throw error;
  }
}

/**
 * Where Google's sign-in returns (redirect URI `<MCP_ORIGIN>/google-callback`). The page only
 * runs its own script, which hands the ID token from the URL fragment to the consent page.
 */
function googleCallback(): Response {
  return html(
    googleCallbackPage(),
    200,
    new Headers({
      "Content-Security-Policy": GOOGLE_CALLBACK_CSP,
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "no-store",
    }),
  );
}

function googleCallbackScript(): Response {
  return new Response(GOOGLE_CALLBACK_SCRIPT, {
    headers: {
      "Content-Type": "text/javascript; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "no-cache",
    },
  });
}

/** The MCP endpoint, stateless: each request builds a server for the grant's user. */
async function mcp(request: Request, ctx: OAuthResourceContext<GrantProps>, backend: ZimamBackend): Promise<Response> {
  const server = buildServer(backend, ctx.props.userId, ctx.auth.scope.includes(SCOPES.write));
  const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
  await server.connect(transport);
  return transport.handleRequest(request);
}

/** Builds the worker; tests pass a fake backend instead of the API service binding. */
export function createWorker(backendFor: (env: Env) => ZimamBackend) {
  let provider: OAuthProvider<Env> | undefined;

  const providerFor = (env: Env) =>
    (provider ??= new OAuthProvider<Env>({
      apiRoute: "/mcp",
      apiHandler: {
        fetch: (request, env, ctx) => mcp(request, ctx as OAuthResourceContext<GrantProps>, backendFor(env)),
      },
      defaultHandler: {
        fetch: (request, env) => {
          const { pathname } = new URL(request.url);
          if (pathname === "/authorize") return authorize(request, env, backendFor(env));
          if (pathname === GOOGLE_CALLBACK_PATH) return googleCallback();
          if (pathname === `${GOOGLE_CALLBACK_PATH}.js`) return googleCallbackScript();
          if (pathname === "/") return html(homePage(env.MCP_ORIGIN));
          return new Response("Not found", { status: 404 });
        },
      },
      authorizeEndpoint: "/authorize",
      tokenEndpoint: "/oauth/token",
      clientRegistrationEndpoint: "/oauth/register",
      clientIdMetadataDocumentEnabled: true,
      scopesSupported: [SCOPES.read, SCOPES.write],
      resourceMetadata: { resource: `${env.MCP_ORIGIN}/mcp`, authorization_servers: [env.MCP_ORIGIN] },
    }));

  return {
    fetch(request: Request, env: Env, ctx: ExecutionContext) {
      return providerFor(env).fetch(request, env, ctx);
    },
  } satisfies ExportedHandler<Env>;
}

export default createWorker((env) => env.API);
