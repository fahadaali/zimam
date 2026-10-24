// Additions to the open task (index.html #inspector, task-pane.js), kept out of main.js: the
// assignee picker and comments (share-view.js), the subtasks with «تقسيم إلى خطوات»
// (assistant-view.js), and «المدة» with the start date (duration-view.js).
// They live in their own container (#task-extras) after #task-details.
import { breakdownSection } from "./assistant-view.js";
import { durationSection } from "./duration-view.js";
import { assigneeSection, commentsSection } from "./share-view.js";

let shown = 0;
/** The extras on screen: the task, its project and parent when they were drawn, and the sections. */
let open = null;

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
  const sections = {
    duration: durationSection(task, scoped),
    assignee: assigneeSection(task, scoped),
    breakdown: task.parentId ? null : breakdownSection(task, scoped),
    comments: task.projectId ? commentsSection(task, scoped) : null,
  };
  box.replaceChildren(...Object.values(sections).filter(Boolean));
  open = { task, projectId: task.projectId ?? null, parentId: task.parentId ?? null, sections };
}

/**
 * The open task changed (an edit in the pane, or a change from elsewhere): the extras follow. Moved
 * to another project, they are drawn again, as its members and comments are other ones; otherwise
 * «المدة» and the assignee update in place, so a form being filled or a comment draft stays.
 */
export function updateTaskExtras(task, ctx) {
  if (open?.task.id !== task.id) return;
  if ((task.projectId ?? null) !== open.projectId || (task.parentId ?? null) !== open.parentId) {
    showTaskExtras(task, ctx);
    return;
  }
  open.sections.duration.update?.();
  open.sections.assignee.update?.();
}

/** Reads the open task's subtasks and comments again: another member may have added some. */
export function reloadTaskExtras(taskId) {
  if (open?.task.id !== taskId) return;
  open.sections.breakdown?.reload?.();
  open.sections.comments?.reload?.();
}
