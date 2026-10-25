// Which of the design system's files the site deploys, read by copy-design.mjs (npm run build), by
// preview.mjs, and by test/design-files.test.mjs. Only what the pages use: the tokens, the fonts they
// name, the two Arabic lockups, the favicon and touch icon, and bundle.css (bundle.js needs React;
// lib/components.js rebuilds it in plain DOM). Paths are inside design/.

const oneOf = (...names) => (name) => names.includes(name);

/** [folder inside design/, which files to copy] */
export const sets = [
  ["generated", oneOf("tokens.css")],
  ["fonts/web", (name) => name.endsWith(".woff2")],
  ["logos", oneOf("zimam-lockup-ar.svg", "zimam-lockup-ar-on-dark.svg")],
  ["app-icons", oneOf("favicon.svg", "apple-touch-icon-180.png")],
  ["components", oneOf("bundle.css")],
];

/** Whether a path under design/ ("logos/zimam-lockup-ar.svg") is copied. */
export const copies = (path) =>
  sets.some(([folder, wanted]) => path.startsWith(`${folder}/`) && !path.slice(folder.length + 1).includes("/") && wanted(path.slice(folder.length + 1)));
