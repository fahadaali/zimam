// Additions to the task details dialog (index.html #task-dialog), kept out of main.js: the assignee
// picker and comments (share-view.js), and the subtasks with «تقسيم إلى خطوات» (assistant-view.js).
// They live in their own container after #task-details, so other additions to the dialog stay
// separate from these.
import { breakdownSection } from "./assistant-view.js";
import { h } from "./lib/components.js";
import { assigneeSection, commentsSection } from "./share-view.js";

let shown = 0;

/**
 * Fills the extras for `task`. `ctx`: { me, primary, today, role, announce, errorText,
 * markLocalChange, onChanged(task) } from main.js. Requests that finish after the dialog moved
 * on to another task are dropped.
 */
export function showTaskExtras(task, ctx) {
  let box = document.getElementById("task-extras");
  if (!box) {
    box = h("div", { className: "task-extras", id: "task-extras" });
    document.getElementById("task-details").after(box);
  }
  const token = ++shown;
  const dialog = document.getElementById("task-dialog");
  const isCurrent = () => token === shown && dialog.open;
  const scoped = { ...ctx, isCurrent };
  box.replaceChildren(
    assigneeSection(task, scoped),
    task.parentId ? null : breakdownSection(task, scoped),
    task.projectId ? commentsSection(task, scoped) : null,
  );
}
