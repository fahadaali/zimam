import type { Context } from "hono";
import { Hono } from "hono";
import { sha256Hex } from "../auth/crypto";
import { addMemberStatements, type MemberRole, outranks } from "../data/membership";
import { fail } from "../http";
import type { AppEnv } from "../types";

export const invites = new Hono<AppEnv>();

interface Invite {
  code_hash: string;
  project_id: string;
  role: MemberRole;
  expires_at: number;
  accepted_at: number | null;
  revoked_at: number | null;
  project_name: string;
  project_deleted_at: number | null;
  inviter_name: string | null;
}

/** Loads the invite named by the `:code` param, or answers why it cannot be used. */
async function usableInvite(c: Context<AppEnv>, now: number): Promise<Invite | Response> {
  const invite = await c.env.DB.prepare(
    `SELECT i.*, p.name AS project_name, p.deleted_at AS project_deleted_at, u.name AS inviter_name
     FROM invites i JOIN projects p ON p.id = i.project_id JOIN users u ON u.id = i.created_by
     WHERE i.code_hash = ?`,
  )
    .bind(await sha256Hex(c.req.param("code")!))
    .first<Invite>();
  if (!invite) return fail(c, 404, "not_found", "invite not found");
  if (invite.project_deleted_at != null) return fail(c, 410, "gone", "The project was deleted");
  if (invite.revoked_at != null) return fail(c, 410, "invite_revoked", "The invite was revoked");
  if (invite.accepted_at != null) return fail(c, 410, "invite_used", "The invite was already used");
  if (invite.expires_at <= now) return fail(c, 410, "invite_expired", "The invite has expired");
  return invite;
}

/** GET /:code — what the invite offers, shown before joining. */
invites.get("/:code", async (c) => {
  const invite = await usableInvite(c, Date.now());
  if (invite instanceof Response) return invite;
  return c.json({
    projectName: invite.project_name,
    role: invite.role,
    invitedBy: invite.inviter_name,
    expiresAt: invite.expires_at,
  });
});

/**
 * POST /:code/accept — joins the project with the invite's role. A member
 * keeps the higher of their role and the invite's; the invite is used only
 * when it grants something.
 */
invites.post("/:code/accept", async (c) => {
  const db = c.env.DB;
  const now = Date.now();
  const invite = await usableInvite(c, now);
  if (invite instanceof Response) return invite;
  const projectId = invite.project_id;
  const current = await c.var.access.role(projectId);
  if (current && !outranks(invite.role, current)) return c.json({ projectId, role: current });

  // Claim first, so two people racing for one link cannot both join.
  const claim = await db
    .prepare(
      `UPDATE invites SET accepted_by = ?2, accepted_at = ?3
       WHERE code_hash = ?1 AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > ?3`,
    )
    .bind(invite.code_hash, c.var.userId, now)
    .run();
  if (claim.meta.changes !== 1) return fail(c, 410, "invite_used", "The invite was already used");

  if (current) {
    await db
      .prepare(`UPDATE project_members SET role = ? WHERE project_id = ? AND user_id = ?`)
      .bind(invite.role, projectId, c.var.userId)
      .run();
  } else {
    await db.batch(addMemberStatements(db, projectId, c.var.userId, invite.role, now));
  }
  c.var.access.invalidate();
  return c.json({ projectId, role: invite.role });
});
