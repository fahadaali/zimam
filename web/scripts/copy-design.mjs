// Copies the design system's web files from ../design into public/design/, keeping their relative
// layout so tokens.css's ../fonts/web/ URLs resolve. Only what the pages use is deployed: the
// tokens, the fonts they name, the two Arabic lockups, the favicon and touch icon, and bundle.css
// (bundle.js needs React; lib/components.js rebuilds it in plain DOM). test/design-files.test.mjs
// checks every /design/ path a page names is among them. design/ stays the only source;
// public/design/ is generated and ignored by git. No dependencies: runs in Workers Builds as
// `npm run build`.
import { cp, mkdir, readdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const design = join(web, "..", "design");
const out = join(web, "public", "design");

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
export const copies = (path) => sets.some(([folder, wanted]) => path.startsWith(`${folder}/`) && !path.slice(folder.length + 1).includes("/") && wanted(path.slice(folder.length + 1)));

async function copyDesign() {
  await rm(out, { recursive: true, force: true });
  let count = 0;
  for (const [folder, wanted] of sets) {
    const from = join(design, folder);
    const names = (await readdir(from)).filter(wanted);
    if (names.length === 0) throw new Error(`No design files found in design/${folder}`);
    await mkdir(join(out, folder), { recursive: true });
    for (const name of names) {
      await cp(join(from, name), join(out, folder, name));
      count++;
    }
  }
  console.log(`Copied ${count} design files into public/design/`);
}

// Run as a script (npm run build), not when a test imports `sets`.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await copyDesign();
