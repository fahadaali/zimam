// Swiping a task row toward the inline start on phones (to the right in Arabic) uncovers «حذف» at
// its inline end, as the app's trailing swipe action (TaskListItem.swift). The row follows the finger one to one from where it was grabbed,
// resists past the button (rubber band), and on release goes where the gesture was heading: the
// release velocity is projected forward (Designing Fluid Interfaces) to choose open or closed.
// A tap elsewhere, or a swipe back, closes it. With Reduce Motion the row moves without easing.

const SLOP = 10; // px of movement before the swipe claims the gesture from scrolling
const DECELERATION = 0.998;

/** Where a release with this velocity (px/ms) would come to rest, as UIScrollView decelerates. */
const project = (velocity) => ((velocity * 1000) / 1000) * DECELERATION / (1 - DECELERATION);

/** Past the end, the row follows less and less: real things slow before they stop. */
function rubberband(overshoot, dimension, constant = 0.55) {
  return (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot));
}

let openRow = null;

function close(li) {
  if (!li) return;
  li.classList.remove("is-swiped");
  li.style.removeProperty("--swipe");
  if (openRow === li) openRow = null;
}

document.addEventListener(
  "pointerdown",
  (event) => {
    if (openRow && !openRow.contains(event.target)) close(openRow);
  },
  true,
);

/**
 * Makes `li` (a .task-item holding a .zm-task row) swipeable on phones. `isCompact()` says whether
 * the phone layout is showing; `onDelete()` deletes the task when «حذف» is pressed.
 */
export function swipeToDelete(li, { isCompact, onDelete, label }) {
  const row = li.querySelector(".zm-task");
  if (!row) return;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "swipe-delete callout";
  button.textContent = "حذف";
  button.setAttribute("aria-label", `حذف المهمة: ${label}`);
  // Only reachable once the row is swiped open; keyboard users delete from the task's page.
  button.tabIndex = -1;
  button.addEventListener("click", () => {
    button.disabled = true;
    onDelete().finally(() => {
      button.disabled = false;
      close(li);
    });
  });
  li.prepend(button);
  li.classList.add("is-swipeable");

  // In Arabic the inline start is the right: a swipe toward it is a positive x.
  const startSign = () => (getComputedStyle(li).direction === "rtl" ? 1 : -1);
  let start = null;
  let suppressUntil = 0;
  li.addEventListener(
    "click",
    (event) => {
      if (event.timeStamp > suppressUntil || event.target.closest(".swipe-delete")) return;
      event.stopPropagation();
      event.preventDefault();
    },
    { capture: true },
  );

  row.addEventListener("pointerdown", (event) => {
    if (!isCompact() || event.pointerType === "mouse" || event.button !== 0) return;
    const current = parseFloat(li.style.getPropertyValue("--swipe")) || 0;
    start = { x: event.clientX, y: event.clientY, id: event.pointerId, base: current, claimed: false, samples: [{ x: event.clientX, t: event.timeStamp }] };
  });

  row.addEventListener("pointermove", (event) => {
    if (!start || event.pointerId !== start.id) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (!start.claimed) {
      if (Math.abs(dy) > SLOP && Math.abs(dy) > Math.abs(dx)) {
        start = null; // a scroll, not a swipe
        return;
      }
      if (Math.abs(dx) < SLOP) return;
      start.claimed = true;
      try {
        row.setPointerCapture(event.pointerId);
      } catch {
        /* the pointer already went away */
      }
      li.classList.add("is-dragging-swipe");
      if (openRow && openRow !== li) close(openRow);
    }
    start.samples.push({ x: event.clientX, t: event.timeStamp });
    if (start.samples.length > 5) start.samples.shift();
    const width = button.offsetWidth;
    // Distance toward the inline start, 0 when closed and `width` when open.
    let along = start.base + dx * startSign();
    if (along < 0) along = rubberband(along, width);
    else if (along > width) along = width + rubberband(along - width, width);
    li.style.setProperty("--swipe", `${along}px`);
  });

  const release = (event) => {
    if (!start || event.pointerId !== start.id) return;
    const claimed = start.claimed;
    const samples = start.samples;
    start = null;
    li.classList.remove("is-dragging-swipe");
    if (!claimed) return;
    // The swipe is over: the click the browser sends right after it must not open the task.
    suppressUntil = event.timeStamp + 350;
    const first = samples[0];
    const last = samples.at(-1);
    const velocity = last.t > first.t ? ((last.x - first.x) / (last.t - first.t)) * startSign() : 0;
    const along = parseFloat(li.style.getPropertyValue("--swipe")) || 0;
    const resting = along + project(velocity);
    if (resting > button.offsetWidth / 2) {
      li.classList.add("is-swiped");
      li.style.setProperty("--swipe", `${button.offsetWidth}px`);
      openRow = li;
      button.tabIndex = 0;
    } else {
      button.tabIndex = -1;
      close(li);
    }
  };
  row.addEventListener("pointerup", release);
  row.addEventListener("pointercancel", release);
}
