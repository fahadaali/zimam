// Additions to the open task (index.html #inspector, task-pane.js), kept out of main.js: the
// assignee picker and comments (share-view.js), the subtasks with «تقسيم إلى خطوات»
// (assistant-view.js), and «المدة» with the start date (duration-view.js).
// They live in their own container (#task-extras) after #task-details.
import { breakdownSection } from "./assistant-view.js";
import { durationSection } from "./duration-view.js";
import { assigneeSection, commentsSection } from "./share-view.js";

let shown = 0;

/**
 * Fills the extras for `task`. `ctx`: { me, primary, today, role, announce, errorText,
 * markLocalChange, onChanged(task), isTaskShown(id) } from main.js and task-pane.js. Requests
 * that finish after the pane moved on to another task, or closed, are dropped.
 */
export function showTaskExtras(task, ctx) {
  const box = document.getElementById("task-extras");
  const token = ++shown;
  const isCurrent = () => token === shown && ctx.isTaskShown(task.id);
  const scoped = { ...ctx, isCurrent };
  box.replaceChildren(
    durationSection(task, scoped),
    assigneeSection(task, scoped),
    task.parentId ? null : breakdownSection(task, scoped),
    task.projectId ? commentsSection(task, scoped) : null,
  );
}
