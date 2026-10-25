// The live preview: the web app (public/app/) inside an iPhone, on the demo data, with no server.
// Builds a folder that any static host can serve, and that is published as a Claude Artifact so
// the app can be watched and tried in the Claude app after each change:
//
//   node scripts/preview.mjs [out]      (default: <tmp>/zimam-preview)
//
// out/index.html is the phone (preview-frame.mjs), written as an Artifact page; out/app/ a copy of
// public/app/ whose root paths are made relative, without Apple's sign-in script, and with
// preview-mock.js loaded before main.js (the API, the clock and the session); out/design/ and
// out/styles/ what the app's <head> asks for. out/files.json maps each published path to its file,
// for the Artifact's `files`. public/ and design/ are only read.
import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sets as designSets } from "./design-files.mjs";
import { previewPage } from "./preview-frame.mjs";

const scripts = dirname(fileURLToPath(import.meta.url));
const web = join(scripts, "..");
const design = join(web, "..", "design");
const out = resolve(process.argv[2] ?? join(tmpdir(), "zimam-preview"));
const MARK = ".zimam-preview";

// The folder is rebuilt from scratch, so only one this script made before is cleared.
try {
  const names = await readdir(out);
  if (names.length > 0 && !names.includes(MARK)) {
    console.error(`${out} is not empty and was not made by this script; choose another folder.`);
    process.exit(1);
  }
  await rm(out, { recursive: true, force: true });
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
await mkdir(out, { recursive: true });
await writeFile(join(out, MARK), "Built by web/scripts/preview.mjs; rebuilt on each run.\n");

/** [from, to inside out/, which files] — the design files as npm run build picks them (design-files.mjs); only app/ has subfolders. */
const copies = [
  [join(web, "public", "app"), "app", (name) => !name.startsWith("google-callback"), true],
  [join(web, "public", "styles"), "styles", (name) => name === "base.css"],
  ...designSets.map(([folder, wanted]) => [join(design, folder), `design/${folder}`, wanted]),
];

async function copyTree(from, to, wanted, deep = false) {
  for (const name of await readdir(from)) {
    const source = join(from, name);
    if ((await stat(source)).isDirectory()) {
      if (deep) await copyTree(source, join(to, name), () => true, true);
    } else if (wanted(name)) {
      await mkdir(to, { recursive: true });
      await cp(source, join(to, name));
    }
  }
}
for (const [from, to, wanted, deep] of copies) await copyTree(from, join(out, to), wanted, deep);

// The demo data and the API that plays the server, beside main.js.
await cp(join(scripts, "demo-data.mjs"), join(out, "app", "demo-data.js"));
await cp(join(scripts, "preview-mock.js"), join(out, "app", "preview-mock.js"));

// The app's page, served from out/app/: root paths made relative to it, no Apple script, and the
// mock first.
const MAIN = '<script type="module" src="/app/main.js"></script>';
let html = await readFile(join(web, "public", "app", "index.html"), "utf8");
if (!html.includes(MAIN)) throw new Error(`public/app/index.html no longer loads main.js as ${MAIN}`);
html = html
  .replace(MAIN, '<script type="module" src="./preview-mock.js"></script>\n<script type="module" src="./main.js"></script>')
  .replace(/<script src="https:\/\/appleid\.cdn-apple\.com[^"]*"[^>]*><\/script>\n?/, "")
  .replaceAll('"/app/', '"./')
  .replaceAll('"/design/', '"../design/')
  .replaceAll('"/styles/', '"../styles/');
await writeFile(join(out, "app", "index.html"), html);

await writeFile(join(out, "index.html"), previewPage());

// Every published file but the page itself, for the Artifact's `files`.
async function list(dir) {
  const found = [];
  for (const name of await readdir(dir)) {
    const path = join(dir, name);
    if ((await stat(path)).isDirectory()) found.push(...(await list(path)));
    else found.push(path);
  }
  return found;
}
const files = Object.fromEntries(
  (await list(out))
    .map((path) => [relative(out, path).split("\\").join("/"), path])
    .filter(([published]) => published !== "index.html" && published !== MARK && published !== "files.json")
    .sort(([a], [b]) => a.localeCompare(b)),
);
await writeFile(join(out, "files.json"), `${JSON.stringify(files, null, 2)}\n`);
console.log(`Preview in ${out}: index.html and ${Object.keys(files).length} files (files.json)`);
