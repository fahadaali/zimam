// Copies the design system's web files from ../design into public/design/, keeping their relative
// layout so tokens.css's ../fonts/web/ URLs resolve. design/ stays the only source; public/design/
// is generated and ignored by git. No dependencies: runs in Workers Builds as `npm run build`.
import { cp, mkdir, readdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const design = join(web, "..", "design");
const out = join(web, "public", "design");

/** [folder inside design/, which files to copy] */
const sets = [
  ["generated", (name) => name === "tokens.css"],
  ["fonts/web", (name) => name.endsWith(".woff2")],
  ["logos", (name) => name.endsWith(".svg")],
  ["app-icons", (name) => /\.(svg|png)$/.test(name)],
  ["components", (name) => name === "bundle.js" || name === "bundle.css"],
];

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
