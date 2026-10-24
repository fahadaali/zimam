// Plain-DOM equivalents of the reference components in design/components/bundle.js (which needs
// React). Same class names, markup and behaviour, so design/components/bundle.css styles them.
// Text always goes in through textContent; nothing here parses HTML.
import { icon } from "./icons.js";
import { arabicNumber } from "./numbers.js";
import { PRIORITY_WORDS } from "./tasks.js";

/** h("div", { className: "x", onclick }, child, "text") */
export function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props ?? {})) {
    if (value == null || value === false) continue;
    if (key === "className") el.className = value;
    else if (key === "dataset") Object.assign(el.dataset, value);
    else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2), value);
    else if (key in el && typeof value !== "string") el[key] = value;
    else el.setAttribute(key, value === true ? "" : value);
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

/** The chip and row icons, from the shared set (lib/icons.js). */
export const icons = {
  check: () => icon("check", { size: "xs", weight: "bold" }),
  flag: () => icon("flag", { size: "sm" }),
  calendar: () => icon("calendar", { size: "xs" }),
  prayer: () => icon("moon-star", { size: "xs" }),
  plus: () => icon("plus", { size: "sm" }),
};

/** Button: variant primary (one per screen), secondary or quiet. */
export function Button({ variant = "primary", type = "button", className, ...rest }, ...children) {
  return h("button", { type, className: ["zm-btn", `zm-btn-${variant}`, className].filter(Boolean).join(" "), ...rest }, ...children);
}

/** A link that looks like a Button. */
export function ButtonLink({ variant = "primary", href, className, ...rest }, ...children) {
  return h("a", { href, className: ["zm-btn", `zm-btn-${variant}`, "zm-btn-link", className].filter(Boolean).join(" "), ...rest }, ...children);
}

/** DateChip: `text` is the near-day word or both calendars already joined with «،». */
export function DateChip({ text, tone = "default", full }) {
  return h(
    "span",
    { className: `zm-chip zm-chip-date${tone === "overdue" ? " zm-chip-overdue" : ""}` },
    icons.calendar(),
    h("span", null, text),
    full && full !== text ? h("span", { className: "zm-sr" }, `، ${full}`) : null,
    tone === "overdue" ? h("span", { className: "zm-sr" }, " متأخرة") : null,
  );
}

/** PrayerChip: sand on sand-soft with the moon and star (moon.stars), as Chips.swift draws it. */
export function PrayerChip(text, spoken) {
  // In a row it shows the clock time on the task's day («٢:٥٠ م»); screen readers hear the phrase after it.
  return h("span", { className: "zm-chip zm-chip-prayer" }, icons.prayer(), h("span", null, text), spoken ? h("span", { className: "zm-sr" }, `، ${spoken}`) : null);
}

/** TimeChip: a task's clock time «٣:٠٠ م», quiet like the date chip (Chips.swift). */
export function TimeChip(text) {
  return h("span", { className: "zm-chip zm-chip-date zm-chip-time" }, h("span", null, text));
}

const FLAG_LEVELS = { low: 1, medium: 2, high: 3 };

export function PriorityFlag(priority) {
  const words = PRIORITY_WORDS[FLAG_LEVELS[priority]];
  if (!words) return null;
  return h("span", { className: `zm-flag zm-flag-${priority}` }, icons.flag(), h("span", { className: "zm-sr" }, words));
}

/**
 * TaskRow. The completion circle toggles; the title is a button that opens the task's details
 * (the reference renders it as text). At most three chips, as TaskRow.swift: the date, then the
 * clock time or the prayer, then the project as plain text. `selected` is the task open beside it.
 */
export function TaskRow({ title, note, done = false, priority, date, time, prayer, project, selected = false, onToggle, onOpen }) {
  const check = h(
    "button",
    {
      type: "button",
      className: `zm-check${done ? " zm-check-on" : ""}`,
      "aria-pressed": done ? "true" : "false",
      "aria-label": `${done ? "إلغاء إنجاز" : "إنجاز"}: ${title}`,
      onclick: onToggle,
    },
    done ? icons.check() : null,
  );
  const meta = [];
  if (date) meta.push(DateChip(date));
  if (prayer) meta.push(typeof prayer === "string" ? PrayerChip(prayer) : PrayerChip(prayer.text, prayer.spoken));
  else if (time) meta.push(TimeChip(time));
  if (project) meta.push(h("span", { className: "zm-meta-text" }, project));
  return h(
    "div",
    { className: `zm-task${done ? " zm-task-done" : ""}${selected ? " zm-task-selected" : ""}` },
    check,
    h(
      "div",
      { className: "zm-task-body" },
      onOpen
        ? h("button", { type: "button", className: "zm-task-title zm-task-open", "aria-current": selected ? "true" : null, onclick: onOpen }, title)
        : h("div", { className: "zm-task-title" }, title),
      note ? h("div", { className: "zm-task-note" }, note) : null,
      meta.length ? h("div", { className: "zm-task-meta" }, meta) : null,
    ),
    PriorityFlag(priority),
  );
}

/** Sets a TaskRow's done state in place, as the reference component re-renders it. */
export function setRowDone(row, done, title) {
  row.classList.toggle("zm-task-done", done);
  const check = row.querySelector(".zm-check");
  check.classList.toggle("zm-check-on", done);
  check.setAttribute("aria-pressed", done ? "true" : "false");
  check.setAttribute("aria-label", `${done ? "إلغاء إنجاز" : "إنجاز"}: ${title}`);
  check.replaceChildren(...(done ? [icons.check()] : []));
}

/** ProjectCard: name, «٧ من ١٢» and a progress bar without a written percentage. */
export function ProjectCard({ name, done = 0, total = 0, href, active = false }) {
  const pct = total ? Math.round((done / total) * 100) : 0;
  const fill = h("div", { className: "zm-progress-fill" });
  fill.style.setProperty("inline-size", `${pct}%`);
  const nameEl = href ? h("a", { className: "zm-project-name zm-project-link", href }, name) : h("div", { className: "zm-project-name" }, name);
  return h(
    "div",
    { className: `zm-card zm-project${active ? " zm-project-active" : ""}` },
    h("div", { className: "zm-project-head" }, nameEl, h("div", { className: "zm-meta-text" }, `${arabicNumber(done)} من ${arabicNumber(total)}`)),
    h(
      "div",
      { className: "zm-progress", role: "progressbar", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(pct), "aria-label": `نسبة الإنجاز في ${name}` },
      fill,
    ),
  );
}

/** Marks the row of the task open beside the list (TaskListItem.swift: brand-soft), in place. */
export function setRowSelected(row, selected) {
  row.classList.toggle("zm-task-selected", selected);
  const open = row.querySelector(".zm-task-open");
  if (!open) return;
  if (selected) open.setAttribute("aria-current", "true");
  else open.removeAttribute("aria-current");
}

/** ScreenHeader: the screen's own large title and a quiet line beneath (TaskListItem.swift). */
export function ScreenHeader(title, subtitle, ...extra) {
  return h(
    "header",
    { className: "view-header" },
    h("h1", { className: "display view-title", tabindex: "-1" }, title),
    subtitle ? h("p", { className: "caption muted view-subtitle" }, subtitle) : null,
    ...extra,
  );
}

/** A 44px toolbar button that shows only its icon; the label is for screen readers and the tooltip. */
export function IconButton({ icon: name, label, className, ...rest }) {
  return h(
    "button",
    { type: "button", className: ["icon-button", className].filter(Boolean).join(" "), "aria-label": label, title: label, ...rest },
    icon(name),
  );
}

/** Light dismiss (a click outside closes it) for a dialog with `closedby="any"`, where Safari does not support that yet. */
export function lightDismiss(dialog) {
  if ("closedBy" in HTMLDialogElement.prototype) return;
  dialog.addEventListener("click", (event) => {
    if (event.target !== dialog) return;
    const r = dialog.getBoundingClientRect();
    const inside = r.top <= event.clientY && event.clientY <= r.bottom && r.left <= event.clientX && event.clientX <= r.right;
    if (!inside) dialog.close();
  });
}

/** Whether keys pressed in `el` belong to it: a text field, a list or editable text, not a checkbox or a button. */
export function isTyping(el) {
  if (typeof Element === "undefined" || !(el instanceof Element)) return false;
  if (el.closest("textarea, select, [contenteditable]:not([contenteditable=false])")) return true;
  return el.matches("input") && !/^(checkbox|radio|button|submit|reset|range|color|file)$/.test(el.type);
}

/** A toolbar row above a screen's title: its buttons sit at the inline end, as the app's toolbar items. */
export function ViewToolbar(...items) {
  return h("div", { className: "view-toolbar" }, ...items);
}
