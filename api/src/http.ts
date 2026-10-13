import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { MutationResult, MutationStatus } from "./data/mutations";

/** Error codes are stable and English; clients show their own Arabic text per code. */
export function fail(c: Context, status: ContentfulStatusCode, code: string, message: string) {
  return c.json({ error: { code, message } }, status);
}

const STATUS: Record<Exclude<MutationStatus, "applied">, ContentfulStatusCode> = {
  invalid: 400,
  forbidden: 403,
  stale: 409,
  gone: 410,
};

export function failMutation(c: Context, result: MutationResult) {
  const status = result.status as Exclude<MutationStatus, "applied">;
  return fail(c, STATUS[status], status, result.message ?? status);
}

export async function readJson(c: Context): Promise<unknown> {
  try {
    return await c.req.json();
  } catch {
    return undefined;
  }
}
