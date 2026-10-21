// «خيارات المشروع»: what each role may do to a project, and the words for it. Pure functions; the
// menus, the rename sheet and the delete question are in project-menu.js. The server enforces the
// same rules (api/src/data/mutations.ts): owners and editors rename and archive, the owner alone deletes.
import { errorText } from "./api.js";
import { canEdit } from "./sharing.js";

/** What the signed-in user may do to `project`, from the role the server lists it with. */
export function projectPermissions(project) {
  const role = project?.role ?? null;
  return { canRename: canEdit(role), canArchive: canEdit(role), canDelete: role === "owner" };
}

/** Projects as the lists show them: the open ones, and the archived ones apart. Folders are neither. */
export function splitArchived(projects = []) {
  const own = projects.filter((p) => p.kind !== "folder");
  return { active: own.filter((p) => !p.archivedAt), archived: own.filter((p) => p.archivedAt) };
}

export const archiveLabel = (project) => (project?.archivedAt ? "استرجاع المشروع" : "أرشفة المشروع");

/** The delete question, and what it takes with it. */
export const deleteQuestion = (name) => `حذف «${name}»؟`;
export const DELETE_NOTE = "تُحذف معه مهامه وأقسامه وتذكيراتها عند كل أعضائه، ولا يمكن استرجاعه.";

/** Under «أرشفة المشروع»: its tasks keep their days in «اليوم» and «القادم». */
export const ARCHIVE_NOTE = "يختفي من القوائم، وتبقى مهامه في مواعيدها. تجده في «المشاريع المؤرشفة» أسفل صفحة المشاريع.";

/** What the live region says after each action. */
export const announcement = {
  renamed: (name) => `صار اسم المشروع «${name}».`,
  archived: (name) => `أُرشف المشروع «${name}».`,
  restored: (name) => `استُرجع المشروع «${name}».`,
  deleted: (name) => `حُذف المشروع «${name}».`,
};

/** A failed action in Arabic: a refused delete names who may delete. */
export function projectErrorText(error, action) {
  if (error?.code === "forbidden") return action === "delete" ? "المالك وحده يحذف المشروع." : "لا تملك صلاحية تعديل هذا المشروع.";
  return errorText(error);
}
