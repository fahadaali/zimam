// Plain-DOM equivalents of the reference components in design/components/bundle.js (which needs
// React). Same class names, markup and behaviour, so design/components/bundle.css styles them.
// Text always goes in through textContent; nothing here parses HTML.
import { arabicNumber } from "./numbers.js";

const SVG = "http://www.w3.org/2000/svg";

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

function svg(build) {
  const root = document.createElementNS(SVG, "svg");
  root.setAttribute("viewBox", "0 0 16 16");
  root.setAttribute("width", "14");
  root.setAttribute("height", "14");
  root.setAttribute("aria-hidden", "true");
  root.setAttribute("class", "zm-ico");
  for (const [tag, attrs] of build) {
    const node = document.createElementNS(SVG, tag);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    root.append(node);
  }
  return root;
}

const stroke = (width) => ({ fill: "none", stroke: "currentColor", "stroke-width": width, "stroke-linecap": "round", "stroke-linejoin": "round" });

export const icons = {
  check: () => svg([["path", { d: "M3.5 8.5l3 3 6-7", ...stroke(2) }]]),
  flag: () => svg([["path", { d: "M4 14V2.5M4 3h7.5l-1.8 2.75L11.5 8.5H4", ...stroke(1.6) }]]),
  calendar: () =>
    svg([
      ["rect", { x: 2.5, y: 3.5, width: 11, height: 10, rx: 2, fill: "none", stroke: "currentColor", "stroke-width": 1.5 }],
      ["path", { d: "M2.5 6.5h11M5.5 2v3M10.5 2v3", ...stroke(1.5) }],
    ]),
  horizon: () =>
    svg([
      ["path", { d: "M4 10.5a4 4 0 0 1 8 0", ...stroke(1.6) }],
      ["path", { d: "M2 13h12M8 2.5v2M3.2 5.2l1.2 1.2M12.8 5.2l-1.2 1.2", ...stroke(1.6) }],
    ]),
  plus: () => svg([["path", { d: "M8 3v10M3 8h10", ...stroke(1.8) }]]),
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

export function PrayerChip(text) {
  return h("span", { className: "zm-chip zm-chip-prayer" }, icons.horizon(), h("span", null, text));
}

const PRIORITY_WORDS = { high: "أولوية عالية", medium: "أولوية متوسطة", low: "أولوية منخفضة" };

export function PriorityFlag(priority) {
  if (!PRIORITY_WORDS[priority]) return null;
  return h("span", { className: `zm-flag zm-flag-${priority}` }, icons.flag(), h("span", { className: "zm-sr" }, PRIORITY_WORDS[priority]));
}

/**
 * TaskRow. The completion circle toggles; the title is a button that opens the task's details
 * (the reference renders it as text). At most three chips: date, prayer, project.
 */
export function TaskRow({ title, note, done = false, priority, date, prayer, project, onToggle, onOpen }) {
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
  if (prayer) meta.push(PrayerChip(prayer));
  if (project) meta.push(h("span", { className: "zm-meta-text" }, project));
  return h(
    "div",
    { className: `zm-task${done ? " zm-task-done" : ""}` },
    check,
    h(
      "div",
      { className: "zm-task-body" },
      onOpen ? h("button", { type: "button", className: "zm-task-title zm-task-open", onclick: onOpen }, title) : h("div", { className: "zm-task-title" }, title),
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
