// Swiping a row on phones uncovers its actions, as the app's swipe actions: toward the inline start
// (to the right in Arabic) the ones at its inline end, such as «حذف» on a task (TaskListItem.swift);
// toward the inline end the ones at its inline start, such as «إعادة التسمية» on a project. The row follows the finger one to one from where it was grabbed,
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
 * Makes `li` swipeable on phones: `row` (inside it) slides and uncovers `end` actions at its inline
 * end or `start` actions at its inline start. Each action is { label, ariaLabel, tone, onClick }:
 * tone "danger" (red), "neutral" (grey) or the brand colour; onClick may return a promise, and
 * the row closes when it settles. `isCompact()` says whether the phone layout is showing.
 */
export function swipeActions(li, { row: rowSelector = ".zm-task", isCompact, start: startActions = [], end: endActions = [] }) {
  const row = li.querySelector(rowSelector);
  if (!row || (startActions.length === 0 && endActions.length === 0)) return;
  row.classList.add("swipe-row");

  const tray = (actions, side) => {
    if (actions.length === 0) return null;
    const el = document.createElement("div");
    el.className = `swipe-tray swipe-tray-${side}`;
    for (const action of actions) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `swipe-action callout${action.tone ? ` swipe-${action.tone}` : ""}`;
      button.textContent = action.label;
      if (action.ariaLabel) button.setAttribute("aria-label", action.ariaLabel);
      // Only reachable once the row is swiped open; keyboard users have the same actions elsewhere.
      button.tabIndex = -1;
      button.addEventListener("click", () => {
        button.disabled = true;
        Promise.resolve(action.onClick()).finally(() => {
          button.disabled = false;
          close(li);
        });
      });
      el.append(button);
    }
    li.prepend(el);
    return el;
  };
  const endTray = tray(endActions, "end");
  const startTray = tray(startActions, "start");
  li.classList.add("is-swipeable");
  const focusable = (open) => {
    for (const button of li.querySelectorAll(".swipe-action")) button.tabIndex = open && open.contains(button) ? 0 : -1;
  };

  // In Arabic the inline start is the right: a swipe toward it is a positive x.
  const startSign = () => (getComputedStyle(li).direction === "rtl" ? 1 : -1);
  let start = null;
  let suppressUntil = 0;
  li.addEventListener(
    "click",
    (event) => {
      if (event.timeStamp > suppressUntil || event.target.closest(".swipe-action")) return;
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
    // Toward the inline start is positive (up to the end tray's width), toward the end negative.
    const max = endTray?.offsetWidth ?? 0;
    const min = -(startTray?.offsetWidth ?? 0);
    let along = start.base + dx * startSign();
    if (along > max) along = max + rubberband(along - max, Math.max(max, 1));
    else if (along < min) along = min + rubberband(along - min, Math.max(-min, 1));
    li.style.setProperty("--swipe", `${along}px`);
  });

  const release = (event) => {
    if (!start || event.pointerId !== start.id) return;
    const claimed = start.claimed;
    const samples = start.samples;
    start = null;
    li.classList.remove("is-dragging-swipe");
    if (!claimed) return;
    // The swipe is over: the click the browser sends right after it must not open the row.
    suppressUntil = event.timeStamp + 350;
    const first = samples[0];
    const last = samples.at(-1);
    const velocity = last.t > first.t ? ((last.x - first.x) / (last.t - first.t)) * startSign() : 0;
    const along = parseFloat(li.style.getPropertyValue("--swipe")) || 0;
    const resting = along + project(velocity);
    const max = endTray?.offsetWidth ?? 0;
    const min = -(startTray?.offsetWidth ?? 0);
    if (max && resting > max / 2) {
      li.classList.add("is-swiped");
      li.style.setProperty("--swipe", `${max}px`);
      openRow = li;
      focusable(endTray);
    } else if (min && resting < min / 2) {
      li.classList.add("is-swiped");
      li.style.setProperty("--swipe", `${min}px`);
      openRow = li;
      focusable(startTray);
    } else {
      focusable(null);
      close(li);
    }
  };
  row.addEventListener("pointerup", release);
  row.addEventListener("pointercancel", release);
}

/** A task row: «حذف» at its inline end. `onDelete()` deletes the task. */
export function swipeToDelete(li, { isCompact, onDelete, label }) {
  swipeActions(li, { isCompact, end: [{ label: "حذف", ariaLabel: `حذف المهمة: ${label}`, tone: "danger", onClick: onDelete }] });
}
