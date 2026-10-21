// Sharing a project on the web: members and roles, invite links, comments and assignees. The same
// rules and wording as ShareProjectView, TaskCommentsSection and ProjectMembers in the Apple app.
// Pure functions, no DOM; tested in test/sharing.test.mjs.
import { inviteLink, isInviteCode, roleName } from "./invites.js";

/** Owners and editors change tasks and sections; viewers read and comment. */
export const canEdit = (role) => role === "owner" || role === "editor";

/** «أنت» for the viewer, the member's name, or «عضو بلا اسم». */
export function memberName(member, me) {
  if (member?.userId && member.userId === me) return "أنت";
  const name = member?.name?.trim();
  return name || "عضو بلا اسم";
}

/** The link to send for a new invite (`POST …/invites` → { code, url }): this site's join page. */
export function inviteShareLink(origin, created) {
  if (isInviteCode(created?.code) && origin) return inviteLink(origin, created.code);
  return created?.url ?? null;
}

/** The message that goes with the link, so the code still works when the link does not open. */
export function inviteMessage(projectName, link, code) {
  return `انضم إلى مشروع «${projectName}» في زمام من هذا الرابط: ${link}\nوإن لم يفتح، فاختر «الانضمام بدعوة» في المشاريع والصق هذا الرمز: ${code}`;
}

/** «دعوة محرر», «دعوة مشاهد». */
export function inviteTitle(role) {
  return `دعوة ${roleName(role)}`;
}

/** The roles an owner can give: editor and viewer (a project has one owner). */
export const GRANTABLE_ROLES = ["editor", "viewer"];

/**
 * The assignee choices for a task: «بلا إسناد», then each member, and «عضو سابق» for someone who left
 * but is still assigned. → [{ value, label }]
 */
export function assigneeOptions(members, { me, current } = {}) {
  const options = [{ value: "", label: "بلا إسناد" }, ...members.map((m) => ({ value: m.userId, label: memberName(m, me) }))];
  if (current && !members.some((m) => m.userId === current)) options.push({ value: current, label: "عضو سابق" });
  return options;
}

/** Whether to offer the picker: a shared project (more than one member), or a task already assigned. */
export function showAssignee(members, current) {
  return members.length > 1 || !!current;
}

/** Arabic text for the sharing endpoints' own error codes, or null to fall back to the general message. */
export function sharingErrorText(code) {
  return (
    {
      owner_cannot_leave: "المالك لا يغادر مشروعه. احذفه من «خيارات المشروع» إن لم تعد تحتاجه.",
      cannot_change_owner: "لا يتغيّر دور المالك.",
      invite_used: "استُعملت هذه الدعوة، فلا تُلغى. أزل العضو إن أردت.",
      forbidden: "لا تملك صلاحية هذا التعديل. المالك وحده يدير الأعضاء والدعوات.",
    }[code] ?? null
  );
}

/** The letter in a person's avatar (AvatarView.swift): the first letter of their name, or «ز» without one. */
export function avatarInitial(name) {
  const first = [...(name ?? "").trim()][0];
  return first ?? "ز";
}
