import type { ImportBundle } from "./model";

/**
 * The extension point for import sources. Each source turns its input into an
 * `ImportBundle`; the importer does the rest (ids, idempotency, writes, progress).
 *
 * - `file`: the user uploads an export (CSV, JSON). `parse` is pure: text in, bundle out.
 * - `token`: the user pastes a personal API token (Todoist). `load` calls the provider.
 * - `oauth`: the same as `token`, but the token comes from the provider's OAuth flow, which
 *   the server runs (`src/imports/oauth.ts`, `src/routes/import-oauth.ts`): its callback puts
 *   the token in the job's first queue message. Adding one means writing its `load`,
 *   registering it in `sources/index.ts`, and its provider in `oauth.ts`; the queue and the
 *   importer need no change.
 */
export type SourceId =
  | "todoist-csv"
  | "todoist-api"
  | "ticktick-csv"
  | "google-tasks"
  | "csv"
  | OAuthSourceId;

/** Sources whose token comes from an OAuth flow (`src/imports/oauth.ts`). */
export type OAuthSourceId =
  | "google-calendar"
  | "microsoft-todo"
  | "notion"
  | "trello"
  | "asana"
  | "ticktick-api"
  | "todoist-oauth"
  | "google-tasks-api"
  | "clickup";

export interface ParseContext {
  /** The user's `settings.timeZone`: dates without a zone are read in it. */
  timeZone: string;
  /** The uploaded file's name, when the source names something after it. */
  fileName: string | null;
}

export interface LoadContext extends ParseContext {
  fetch: typeof fetch;
}

interface SourceBase {
  id: SourceId;
  /** Shown in messages: «Todoist». */
  label: string;
  /** `external_refs.source`: records from sources sharing it are the same records. */
  refSource: string;
}

export interface FileSource extends SourceBase {
  input: "file";
  /** Accepted file extensions, lowercase, with the dot. */
  extensions: string[];
  parse(text: string, ctx: ParseContext): ImportBundle;
}

export interface TokenSource extends SourceBase {
  input: "token" | "oauth";
  /** Reads everything with the token. Throws ImportError (bad token) or TransientImportError (try later). */
  load(token: string, ctx: LoadContext): Promise<ImportBundle>;
}

export type Source = FileSource | TokenSource;

/**
 * Record keys. A native key is the provider's own id and is stored as is in
 * `external_refs`, ready for two-way sync later. A derived key is built from names
 * and positions (CSV exports have no ids) and is stored only as its SHA-256.
 */
export const nativeKey = (kind: string, id: string | number) => `${kind}:${id}`;
export const derivedKey = (...parts: (string | number | null)[]) => `~${parts.map((p) => p ?? "").join("\u001f")}`;
export const isDerivedKey = (key: string) => key.startsWith("~");

/** Counts repeated names in one place, so two tasks called «اتصال» get different keys. */
export class Occurrences {
  private seen = new Map<string, number>();
  next(...parts: (string | number | null)[]): number {
    const id = parts.join("\u001f");
    const n = (this.seen.get(id) ?? 0) + 1;
    this.seen.set(id, n);
    return n;
  }
}
