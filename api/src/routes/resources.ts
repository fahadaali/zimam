import type { Context } from "hono";
import { failMutation, fail, readJson } from "../http";
import type { Access } from "../data/access";
import { OUT, type Row, TABLES } from "../data/rows";
import type { EntityName } from "../data/schemas";
import type { AppEnv } from "../types";

/** Fields a REST client may not set; the server owns them. */
const SERVER_FIELDS = ["id", "ownerId", "authorId", "createdAt", "updatedAt"];

function stripServerFields(body: unknown): Record<string, unknown> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return {};
  return Object.fromEntries(Object.entries(body).filter(([k]) => !SERVER_FIELDS.includes(k)));
}

async function visible(access: Access, entity: "project" | "task", row: Row): Promise<boolean> {
  if (row.deleted_at != null) return false;
  return entity === "project" ? (await access.role(row.id as string)) !== null : access.canSeeTask(row);
}

export async function loadVisible(c: Context<AppEnv>, entity: "project" | "task", id: string): Promise<Row | null> {
  const row = await c.env.DB.prepare(`SELECT * FROM ${TABLES[entity]} WHERE id = ?`).bind(id.toLowerCase()).first<Row>();
  return row && (await visible(c.var.access, entity, row)) ? row : null;
}

async function respondWith(c: Context<AppEnv>, entity: EntityName, id: string, status: 200 | 201) {
  const row = await c.env.DB.prepare(`SELECT * FROM ${TABLES[entity]} WHERE id = ?`).bind(id).first<Row>();
  return c.json(OUT[entity](row!), status);
}

/** POST: the server picks the id and timestamp, then applies it like a synced upsert. */
export async function createResource(c: Context<AppEnv>, entity: "project" | "task") {
  const id = crypto.randomUUID();
  const data = { ...stripServerFields(await readJson(c)), id, updatedAt: Date.now() };
  const result = await c.var.mutator.apply({ op: "upsert", entity, data });
  return result.status === "applied" ? respondWith(c, entity, id, 201) : failMutation(c, result);
}

/** PATCH: merges the body over the current record. */
export async function updateResource(c: Context<AppEnv>, entity: "project" | "task", id: string, patch?: Record<string, unknown>) {
  const row = await loadVisible(c, entity, id);
  if (!row) return fail(c, 404, "not_found", `${entity} not found`);
  const current = OUT[entity](row);
  const data = {
    ...current,
    ...(patch ?? stripServerFields(await readJson(c))),
    id: current.id,
    updatedAt: Math.max(Date.now(), (row.updated_at as number) + 1),
  };
  const result = await c.var.mutator.apply({ op: "upsert", entity, data });
  return result.status === "applied" ? respondWith(c, entity, current.id as string, 200) : failMutation(c, result);
}

export async function deleteResource(c: Context<AppEnv>, entity: "project" | "task", id: string) {
  const row = await loadVisible(c, entity, id);
  if (!row) return fail(c, 404, "not_found", `${entity} not found`);
  const updatedAt = Math.max(Date.now(), (row.updated_at as number) + 1);
  const result = await c.var.mutator.apply({ op: "delete", entity, id: row.id, updatedAt });
  return result.status === "applied" ? c.body(null, 204) : failMutation(c, result);
}
