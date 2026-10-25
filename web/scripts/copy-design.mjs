// Copies the design system's web files from ../design into public/design/, keeping their relative
// layout so tokens.css's ../fonts/web/ URLs resolve. Which files is in design-files.mjs (only what
// the pages use), and test/design-files.test.mjs checks every /design/ path a page names is among
// them. design/ stays the only source; public/design/ is generated and ignored by git. No
// dependencies: runs in Workers Builds as `npm run build`.
import { cp, mkdir, readdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { sets } from "./design-files.mjs";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const design = join(web, "..", "design");
const out = join(web, "public", "design");

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
