import { ImportError, TransientImportError } from "../model";

/**
 * Reading a provider's API with the token from its OAuth flow. Failures map to what the queue
 * does with them: a rejected token fails the job at once (`ImportError`), a provider that is
 * down or rate-limiting is retried (`TransientImportError`). Messages name the provider, the
 * path and the HTTP status only: never the token, the query or the body.
 */
export interface Provider {
  /** «Google Calendar»: the provider's name in messages. */
  label: string;
  fetch: typeof fetch;
  /** Headers on every request, with the token. */
  headers: Record<string, string>;
}

/** The job's message when the provider refuses the token: the user may have revoked it, or refused a permission. */
export function tokenRejected(label: string): ImportError {
  return new ImportError(
    "token_rejected",
    `رفض ${label} إذن الوصول. ابدأ الاستيراد مرة أخرى ووافق على كل الأذونات التي يطلبها زمام.`,
  );
}

/**
 * One JSON request. `optional`: a 404 gives null instead of failing (an endpoint some accounts
 * do not have, like TickTick's inbox).
 */
export async function providerJson<T>(
  provider: Provider,
  url: string,
  init: { method?: string; body?: unknown; optional?: boolean } = {},
): Promise<T | null> {
  const path = new URL(url).pathname;
  const headers: Record<string, string> = { Accept: "application/json", ...provider.headers };
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  let response: Response;
  try {
    response = await provider.fetch(url, {
      method: init.method ?? "GET",
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    });
  } catch {
    throw new TransientImportError(`${provider.label} ${path}: network error`);
  }
  if (response.status === 401 || response.status === 403) throw tokenRejected(provider.label);
  if (response.status === 404 && init.optional) return null;
  if (response.status === 429 || response.status >= 500) {
    const retryAfter = Number(response.headers.get("Retry-After"));
    throw new TransientImportError(`${provider.label} ${path}: HTTP ${response.status}`, Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : undefined);
  }
  if (!response.ok) {
    throw new ImportError("source_error", `رفض ${provider.label} الطلب (${response.status}). أعد المحاولة لاحقاً.`);
  }
  try {
    return (await response.json()) as T;
  } catch {
    throw new TransientImportError(`${provider.label} ${path}: unreadable response`);
  }
}

/** The same, for endpoints that always exist. */
export async function providerGet<T>(provider: Provider, url: string, init: { method?: string; body?: unknown } = {}): Promise<T> {
  return (await providerJson<T>(provider, url, init)) as T;
}

/** Most pages one listing follows: a guard against a provider that never stops paging. */
export const MAX_PAGES = 200;

/** HTML (Google Calendar descriptions, Outlook task bodies) as plain text: line breaks kept, tags dropped. */
export function htmlToText(html: string): string {
  return html
    .replace(/<\s*br\s*\/?>/gi, "\n")
    .replace(/<\s*\/\s*(p|div|li|h[1-6]|tr)\s*>/gi, "\n")
    .replace(/<\s*li[^>]*>/gi, "• ")
    .replace(/<[^>]*>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** A provider's instant ("2026-10-20T06:00:00.000Z") as epoch ms, or null. */
export function instantOf(value: string | null | undefined): number | null {
  if (!value) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}
