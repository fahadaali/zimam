// The sidebar on wide screens (SidebarView.swift): counts of open top-level tasks for «اليوم»
// (due today or earlier), «صندوق المهام» (no project), each project and each section, and the
// projects in their order. Pure functions; tested in test/sidebar.test.mjs.

/** { today, inbox, byProject: Map(id → n), bySection: Map(id → n) } from the open tasks. */
export function sidebarCounts(openTasks, today) {
  const counts = { today: 0, inbox: 0, byProject: new Map(), bySection: new Map() };
  for (const task of openTasks) {
    if (task.parentId || task.status === "done") continue;
    if (task.dueDate && task.dueDate <= today) counts.today++;
    if (!task.projectId) counts.inbox++;
    else counts.byProject.set(task.projectId, (counts.byProject.get(task.projectId) ?? 0) + 1);
    if (task.sectionId) counts.bySection.set(task.sectionId, (counts.bySection.get(task.sectionId) ?? 0) + 1);
  }
  return counts;
}

/** Projects as the sidebar lists them: real projects, not archived, by their order, each with its sections. */
export function sidebarProjects(projects, sectionsById = new Map()) {
  return projects
    .filter((p) => p.kind !== "folder" && !p.archivedAt)
    .map((p, index) => ({ project: p, index, sections: [...(sectionsById.get(p.id) ?? [])].sort(bySortOrder) }))
    .sort((a, b) => (a.project.sortOrder ?? 0) - (b.project.sortOrder ?? 0) || a.index - b.index)
    .map(({ project, sections }) => ({ project, sections }));
}

const bySortOrder = (a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0);
