// Line icons for the web app, drawn close to the SF Symbols the Apple app uses (design/README.md
// «الأيقونات»): 24×24, rounded 1.75px strokes in the colour of their text. The shapes are Lucide's
// (lucide.dev, ISC licence). Built with createElementNS only, as the CSP allows no inline markup.
// `mirror` icons point along the reading direction and flip in Arabic.

const SVG = "http://www.w3.org/2000/svg";

const p = (d) => ["path", { d }];
const circle = (cx, cy, r) => ["circle", { cx, cy, r }];
const rect = (x, y, width, height, rx) => ["rect", { x, y, width, height, rx }];
const FOLDER = p("M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z");

/** name → shapes. The SF Symbol each one stands for is beside it. */
export const ICON_PATHS = {
  sun: [circle(12, 12, 4), p("M12 2v2M12 20v2m-7.07-17.07 1.41 1.41m11.32 11.32 1.41 1.41M2 12h2m16 0h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41")], // sun.max
  calendar: [rect(3, 4, 18, 18, 2), p("M8 2v4M16 2v4M3 10h18")], // calendar
  "calendar-clock": [p("M21 7.5V6a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h3.5M16 2v4M8 2v4M3 10h5"), circle(16, 16, 6), p("M16 14v2.3l1.5 1.2")], // calendar.badge.clock
  folder: [FOLDER], // folder
  "folder-plus": [FOLDER, p("M12 10v6M9 13h6")], // folder.badge.plus
  inbox: [p("M22 12h-6l-2 3h-4l-2-3H2"), p("M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z")], // tray
  timeline: [p("M3 3v16a2 2 0 0 0 2 2h16"), p("M7 7h7M10 12h8M8 17h5")], // calendar.day.timeline
  matrix: [rect(3, 3, 18, 18, 2), p("M3 12h18M12 3v18")], // square.grid.2x2
  section: [rect(3, 3, 18, 18, 2), p("M9 3v18M15 3v18")], // rectangle.split.3x1
  search: [circle(11, 11, 8), p("m21 21-4.3-4.3")], // magnifyingglass
  plus: [p("M5 12h14M12 5v14")], // plus
  "user-plus": [p("M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"), circle(9, 7, 4), p("M19 8v6M22 11h-6")], // person.badge.plus
  users: [p("M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"), circle(9, 7, 4), p("M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75")], // person.2
  x: [p("M18 6 6 18M6 6l12 12")], // xmark
  check: [p("M20 6 9 17l-5-5")], // checkmark
  undo: [p("M9 14 4 9l5-5"), p("M4 9h10.5a5.5 5.5 0 0 1 0 11H11")], // arrow.uturn.backward
  "moon-star": [p("M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"), p("M20 3v4M22 5h-4")], // moon.stars
  flag: [p("M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"), p("M4 22v-7")], // flag.fill
  "chevron-back": [p("m15 18-6-6 6-6")], // chevron.backward
  "chevron-forward": [p("m9 18 6-6-6-6")], // chevron.forward
  refresh: [p("M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8M21 3v5h-5M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16M8 16H3v5")], // arrow.triangle.2.circlepath
  "log-out": [p("M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9")], // rectangle.portrait.and.arrow.right
  download: [p("M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3")], // square.and.arrow.down
  summary: [p("M21 6H3M21 12H9M21 18H7")], // text.alignright
  ellipsis: [circle(12, 12, 1), circle(19, 12, 1), circle(5, 12, 1)], // ellipsis
};

/** Icons that follow the reading direction, flipped in Arabic by .zm-ico-mirror (shell.css). */
const MIRRORED = new Set(["chevron-back", "chevron-forward", "undo", "log-out", "timeline"]);
/** Shapes drawn filled, as the filled SF Symbol is (flag.fill). */
const FILLED = new Set(["flag"]);

/**
 * An <svg> for `name`. `size` is a class suffix (shell.css: xs 14px, sm 16px, md 20px, lg 24px);
 * `weight: "bold"` draws a heavier stroke for small marks such as the check in the completion circle.
 */
export function icon(name, { size = "md", weight } = {}) {
  const shapes = ICON_PATHS[name];
  if (!shapes) throw new RangeError(`Unknown icon: ${name}`);
  const root = document.createElementNS(SVG, "svg");
  root.setAttribute("viewBox", "0 0 24 24");
  root.setAttribute("aria-hidden", "true");
  root.setAttribute("focusable", "false");
  root.setAttribute("fill", "none");
  root.setAttribute("stroke", "currentColor");
  root.setAttribute("stroke-width", weight === "bold" ? "3" : "1.75");
  root.setAttribute("stroke-linecap", "round");
  root.setAttribute("stroke-linejoin", "round");
  root.setAttribute("class", ["zm-ico", `zm-ico-${size}`, MIRRORED.has(name) ? "zm-ico-mirror" : null].filter(Boolean).join(" "));
  shapes.forEach(([tag, attrs], index) => {
    const node = document.createElementNS(SVG, tag);
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, String(value));
    // Only the first shape of a filled icon is filled (the flag, not its pole).
    if (FILLED.has(name) && index === 0) node.setAttribute("fill", "currentColor");
    root.append(node);
  });
  return root;
}

/** Fills every `[data-icon]` placeholder under `root` (the static markup in app/index.html). */
export function hydrateIcons(root = document) {
  for (const slot of root.querySelectorAll("[data-icon]")) {
    if (slot.firstElementChild) continue;
    slot.append(icon(slot.dataset.icon, { size: slot.dataset.iconSize ?? "md" }));
  }
}
