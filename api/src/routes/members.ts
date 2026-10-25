import type { Context } from "hono";
import { Hono } from "hono";
import { z } from "zod";
import { randomToken, sha256Hex } from "../auth/crypto";
import type { Role } from "../data/access";
import { listMembers, loadMember, MEMBER_ROLES, removeMemberStatements } from "../data/membership";
import { fail, readJson } from "../http";
import type { AppEnv } from "../types";
import { loadVisible } from "./resources";

// The web join page (web/public/join/), with the code in the fragment so it never reaches a
// server log. Same site as ZimamWeb.origin in the app (apple/ZimamKit) and the
// apple-app-site-association file.
const INVITE_URL = "https://zimam.work/join/#";
const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

const RoleBody = z.object({ role: z.enum(MEMBER_ROLES) }).strict();

/** Project membership and invites, mounted under /v1/projects. */
export const members = new Hono<AppEnv>();

/** The caller's role in a live project, or a 404 for projects they cannot see. */
async function myRole(c: Context<AppEnv>): Promise<{ projectId: string; role: Role } | Response> {
  const projectId = c.req.param("id")!.toLowerCase();
  const role = await c.var.access.role(projectId);
  return role ? { projectId, role } : fail(c, 404, "not_found", "project not found");
}

const ownerOnly = (c: Context<AppEnv>, message: string) => fail(c, 403, "forbidden", message);

members.get("/:id/members", async (c) => {
  const me = await myRole(c);
  if (me instanceof Response) return me;
  return c.json({ members: await listMembers(c.env.DB, me.projectId) });
});

/** PATCH /:id/members/:userId { role } — the owner switches a member between editor and viewer. */
members.patch("/:id/members/:userId", async (c) => {
  const me = await myRole(c);
  if (me instanceof Response) return me;
  if (me.role !== "owner") return ownerOnly(c, "Only the owner can change roles");
  const body = RoleBody.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "role must be editor or viewer");
  const userId = c.req.param("userId").toLowerCase();
  const member = await loadMember(c.env.DB, me.projectId, userId);
  if (!member) return fail(c, 404, "not_found", "member not found");
  if (member.role === "owner") return fail(c, 400, "cannot_change_owner", "The owner's role cannot change");

  await c.env.DB.prepare(`UPDATE project_members SET role = ? WHERE project_id = ? AND user_id = ?`)
    .bind(body.data.role, me.projectId, userId)
    .run();
  c.var.access.invalidate();
  return c.json({ ...member, role: body.data.role });
});

/** DELETE /:id/members/:userId — the owner removes a member, or a member leaves. */
members.delete("/:id/members/:userId", async (c) => {
  const me = await myRole(c);
  if (me instanceof Response) return me;
  const userId = c.req.param("userId").toLowerCase();
  const self = userId === c.var.userId;
  if (!self && me.role !== "owner") return ownerOnly(c, "Only the owner can remove members");
  const member = self ? { role: me.role } : await loadMember(c.env.DB, me.projectId, userId);
  if (!member) return fail(c, 404, "not_found", "member not found");
  if (member.role === "owner") return fail(c, 400, "owner_cannot_leave", "The owner cannot leave; delete the project instead");

  await c.env.DB.batch(removeMemberStatements(c.env.DB, me.projectId, userId, Date.now()));
  c.var.access.invalidate();
  return c.body(null, 204);
});

/** Active invites, without their codes: only the link holder has those. */
members.get("/:id/invites", async (c) => {
  const me = await myRole(c);
  if (me instanceof Response) return me;
  if (me.role !== "owner") return ownerOnly(c, "Only the owner can see invites");
  const { results } = await c.env.DB.prepare(
    `SELECT id, role, created_by, created_at, expires_at FROM invites
     WHERE project_id = ? AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > ?
     ORDER BY created_at`,
  )
    .bind(me.projectId, Date.now())
    .all<{ id: string; role: string; created_by: string; created_at: number; expires_at: number }>();
  return c.json({
    invites: results.map((r) => ({
      id: r.id,
      role: r.role,
      createdBy: r.created_by,
      createdAt: r.created_at,
      expiresAt: r.expires_at,
    })),
  });
});

/** DELETE /:id/invites/:inviteId — the owner revokes a link before it is used. Revoking twice is fine. */
members.delete("/:id/invites/:inviteId", async (c) => {
  const me = await myRole(c);
  if (me instanceof Response) return me;
  if (me.role !== "owner") return ownerOnly(c, "Only the owner can revoke invites");
  const db = c.env.DB;
  const id = c.req.param("inviteId").toLowerCase();
  const invite = await db
    .prepare(`SELECT accepted_at, revoked_at FROM invites WHERE id = ? AND project_id = ?`)
    .bind(id, me.projectId)
    .first<{ accepted_at: number | null; revoked_at: number | null }>();
  if (!invite) return fail(c, 404, "not_found", "invite not found");
  if (invite.accepted_at != null) return fail(c, 410, "invite_used", "The invite was already used");
  if (invite.revoked_at == null) {
    // Guarded, so an invite accepted in the meantime stays accepted.
    const revoked = await db
      .prepare(`UPDATE invites SET revoked_at = ?2 WHERE id = ?1 AND accepted_at IS NULL AND revoked_at IS NULL`)
      .bind(id, Date.now())
      .run();
    if (revoked.meta.changes !== 1) return fail(c, 410, "invite_used", "The invite was already used");
  }
  return c.body(null, 204);
});

/** POST /:id/invites { role } — a single-use link valid for 7 days. */
members.post("/:id/invites", async (c) => {
  const me = await myRole(c);
  if (me instanceof Response) return me;
  if (me.role !== "owner") return ownerOnly(c, "Only the owner can invite");
  const body = RoleBody.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "role must be editor or viewer");
  // Sharing a folder would not share the projects inside it.
  const project = await loadVisible(c, "project", me.projectId);
  if (project?.kind !== "project") return fail(c, 400, "invalid", "Only projects can be shared");
  // A folder turned back into a project still holding projects (the owner's, unshared) is one too.
  const holds = await c.env.DB.prepare(`SELECT 1 FROM projects WHERE parent_id = ? AND deleted_at IS NULL LIMIT 1`)
    .bind(me.projectId)
    .first();
  if (holds) return fail(c, 400, "invalid", "A project that holds projects cannot be shared");

  const code = randomToken();
  const id = crypto.randomUUID();
  const now = Date.now();
  const expiresAt = now + INVITE_TTL_MS;
  await c.env.DB.prepare(
    `INSERT INTO invites (id, code_hash, project_id, role, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(id, await sha256Hex(code), me.projectId, body.data.role, c.var.userId, now, expiresAt)
    .run();
  return c.json({ id, code, url: `${INVITE_URL}${code}`, expiresAt }, 201);
});
