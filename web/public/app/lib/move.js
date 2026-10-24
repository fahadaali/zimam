// «نقل إلى مشروع…» (MoveToProjectSheet.swift): the places a task can move to. «صندوق المهام», then
// each project the person edits, in the sidebar's order, with its sections under it. The task's
// current place is marked. Pure functions, no DOM; tested in test/move.test.mjs.
import { canEdit } from "./sharing.js";
import { sidebarProjects } from "./sidebar.js";

export const INBOX_NAME = "صندوق المهام";

/** The drag data type a task row carries (main.js) and the sidebar's drop reads (shell.js). */
export const TASK_DRAG_TYPE = "application/x-zimam-task";

/** Projects a task can move into: projects (not folders), not archived, that the person edits. */
export function movableProjects(projects) {
  return (projects ?? []).filter((p) => (p.kind ?? "project") === "project" && !p.archivedAt && canEdit(p.role ?? "owner"));
}

/** The sections already on the project objects (GET /v1/projects may carry them): id → sections. */
export function knownSections(projects) {
  const out = new Map();
  for (const p of projects ?? []) if (Array.isArray(p.sections)) out.set(p.id, p.sections);
  return out;
}

/**
 * The destinations, in order: [{ kind: "inbox" | "project" | "section", projectId, sectionId, name,
 * label (for the announcement), spoken (the row's accessible name), current }]. `sectionsById`
 * maps a project id to its sections; a project missing from it is listed without them.
 */
export function moveDestinations(task, projects, sectionsById = new Map()) {
  const here = { projectId: task?.projectId ?? null, sectionId: task?.sectionId ?? null };
  const isCurrent = (projectId, sectionId) => here.projectId === projectId && here.sectionId === sectionId;
  const out = [{ kind: "inbox", projectId: null, sectionId: null, name: INBOX_NAME, label: INBOX_NAME, spoken: INBOX_NAME, current: isCurrent(null, null) }];
  for (const { project, sections } of sidebarProjects(movableProjects(projects), sectionsById)) {
    out.push({ kind: "project", projectId: project.id, sectionId: null, name: project.name, label: project.name, spoken: project.name, current: isCurrent(project.id, null) });
    for (const section of sections) {
      if (section.deletedAt) continue;
      out.push({
        kind: "section",
        projectId: project.id,
        sectionId: section.id,
        name: section.name,
        label: `${section.name} في ${project.name}`,
        spoken: `${section.name}، في ${project.name}`,
        current: isCurrent(project.id, section.id),
      });
    }
  }
  return out;
}
