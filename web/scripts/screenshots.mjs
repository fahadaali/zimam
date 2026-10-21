// The website's screenshots, taken from the web app itself (public/app/) with demo data
// (scripts/demo-data.mjs), so the landing page shows Zimam's real screens and they can be taken
// again whenever the app changes: `npm run screenshots` (after `npm run build`, which it runs).
// Phone, iPad and Mac sizes, light and dark, saved as WebP in public/images/screens/. The phone and
// iPad pictures come framed in the device, with its status bar (scripts/device-frame.mjs); the
// Mac's window is drawn by the page (styles/site.css).
//
// Needs Playwright and Chromium, which the site itself does not: `npm i -g playwright` and
// `npx playwright install chromium`, or set CHROMIUM_PATH to a Chromium already installed.
import { execFileSync } from "node:child_process";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import http from "node:http";
import { createRequire } from "node:module";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { NOW, answer } from "./demo-data.mjs";
import { appViewport, DEVICES, frameHtml, frameSize } from "./device-frame.mjs";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const root = join(web, "public");
const out = join(root, "images", "screens");

async function loadPlaywright() {
  try {
    return await import("playwright");
  } catch {
    try {
      const global = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
      return createRequire(join(global, "noop.js"))("playwright");
    } catch {
      console.error("Playwright is needed: npm i -g playwright && npx playwright install chromium");
      process.exit(1);
    }
  }
}

// ——— A static server for public/, as Workers static assets serve it ———

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".woff2": "font/woff2", ".png": "image/png", ".webp": "image/webp" };

function serve() {
  const server = http.createServer(async (req, res) => {
    let path = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
    if (path.endsWith("/")) path += "index.html";
    let file = join(root, path);
    try {
      if ((await stat(file)).isDirectory()) file = join(file, "index.html");
      const body = await readFile(file);
      res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" });
      res.end(body);
    } catch {
      res.writeHead(404);
      res.end();
    }
  });
  return new Promise((resolve) => server.listen(0, () => resolve(server)));
}

// ——— The screens ———

// The app is shown below the device's status bar, as it lays out inside the safe area.
const SIZES = {
  phone: { viewport: appViewport("phone"), deviceScaleFactor: DEVICES.phone.scale, isMobile: true, hasTouch: true },
  tablet: { viewport: appViewport("tablet"), deviceScaleFactor: DEVICES.tablet.scale },
  desktop: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1.5 },
};

/**
 * The bottom safe area the device gives the page (env(safe-area-inset-bottom)), which a desktop
 * browser reports as 0: the same rules the app's CSS writes, with the device's inset in them.
 */
const SAFE_AREA = {
  phone: `.tabbar{padding-block-end:34px!important}
.fab{inset-block-end:calc(var(--tabbar) + var(--space-4) + 34px)!important}
.sheet{padding-block-end:34px!important}`,
  tablet: `.fab{inset-block-end:calc(var(--space-4) + 20px)!important}`,
};

// What the status bar says at NOW: «٩:٤١»، and on the iPad the day too, «الأربعاء ٢١ أكتوبر».
const STATUS_TIME = new Intl.DateTimeFormat("ar-SA-u-nu-arab", { timeZone: "Asia/Riyadh", hour: "numeric", minute: "2-digit", hour12: true })
  .formatToParts(new Date(NOW))
  .filter((p) => p.type === "hour" || p.type === "minute" || p.type === "literal")
  .map((p) => p.value)
  .join("")
  .trim();
const STATUS_DATE = new Intl.DateTimeFormat("ar-SA-u-nu-arab-ca-gregory", { timeZone: "Asia/Riyadh", weekday: "long", day: "numeric", month: "long" })
  .formatToParts(new Date(NOW))
  .filter((p) => p.type !== "literal")
  .map((p) => p.value)
  .join(" ");

/** name → [size, route, what to do before the picture] */
const SHOTS = {
  "phone-today": ["phone", "#/today"],
  "phone-task": ["phone", "#/today?task=t-contract"],
  "phone-add": [
    "phone",
    "#/today",
    async (page) => {
      await page.click("#add-button");
      await page.fill("#add-title-input", "ذكرني أراجع العقد بعد المغرب يوم الخميس");
      await page.click("text=اقتراح بالمساعد");
      await page.waitForSelector(".zm-ai");
    },
  ],
  "phone-prayer": ["phone", "#/today", (page) => page.click(".prayer-line")],
  "tablet-calendar": ["tablet", "#/calendar"],
  "desktop-today": ["desktop", "#/today?task=t-contract"],
  "desktop-board": ["desktop", "#/projects/p-home"],
  "desktop-timeline": ["desktop", "#/timeline"],
  "desktop-matrix": ["desktop", "#/matrix"],
};

/**
 * Date and time fields as Safari draws them in Arabic, which Chromium does not: it writes them in
 * its own way (10/21/2026), with a calendar icon no Arabic iPhone or Mac shows. On the iPhone and
 * iPad «٢١ أكتوبر ٢٠٢٦», on the Mac «٢١‏/١٠‏/٢٠٢٦»; and on a touch screen no textarea resize grip.
 */
function asSafari(touch) {
  const date = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-arab", touch ? { day: "numeric", month: "long", year: "numeric" } : { day: "numeric", month: "numeric", year: "numeric" });
  const time = new Intl.DateTimeFormat("ar-SA-u-nu-arab", { hour: "numeric", minute: "2-digit" });
  for (const input of document.querySelectorAll('input[type="date"], input[type="time"]')) {
    if (!input.value) continue;
    const text = input.type === "date" ? date.format(new Date(`${input.value}T12:00:00`)) : time.format(new Date(`2000-01-01T${input.value}:00`));
    input.type = "text";
    input.value = text;
  }
  if (touch) for (const area of document.querySelectorAll("textarea")) area.style.setProperty("resize", "none");
}

/** Fixes the clock at NOW and signs in, before any of the app's code runs. */
function prepare(now) {
  const fixed = new Date(now).getTime();
  const RealDate = Date;
  globalThis.Date = class extends RealDate {
    constructor(...args) {
      super(...(args.length ? args : [fixed]));
    }
    static now() {
      return fixed;
    }
  };
  try {
    localStorage.setItem("zimam.session", "demo");
  } catch {
    /* about:blank */
  }
}

const { chromium } = await loadPlaywright();
const only = process.argv.slice(2);
const server = await serve();
const base = `http://localhost:${server.address().port}/app/`;
const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
const converter = await browser.newPage();
const origin = `http://localhost:${server.address().port}`;

/** The app's screenshot framed in its device, as a transparent PNG. */
async function framed(device, png) {
  const { width, height } = frameSize(device);
  const context = await browser.newContext({ viewport: { width: Math.ceil(width), height: Math.ceil(height) }, deviceScaleFactor: DEVICES[device].scale });
  const page = await context.newPage();
  await page.setContent(
    frameHtml(device, {
      screen: `data:image/png;base64,${png.toString("base64")}`,
      time: STATUS_TIME,
      date: device === "tablet" ? STATUS_DATE : null,
      font: `${origin}/design/fonts/web/thmanyahsans-Bold.woff2`,
    }),
  );
  await page.waitForSelector("body[data-ready]");
  await page.evaluate(() => document.fonts.ready);
  const result = await page.screenshot({ type: "png", omitBackground: true });
  await context.close();
  return result;
}
await mkdir(out, { recursive: true });

/** PNG bytes to WebP, by the browser's own encoder: no image package needed. */
async function toWebp(png) {
  const dataUrl = await converter.evaluate(async (b64) => {
    const image = new Image();
    image.src = `data:image/png;base64,${b64}`;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = image.naturalWidth;
    canvas.height = image.naturalHeight;
    canvas.getContext("2d").drawImage(image, 0, 0);
    return canvas.toDataURL("image/webp", 0.85);
  }, png.toString("base64"));
  return Buffer.from(dataUrl.split(",")[1], "base64");
}

let total = 0;
for (const scheme of ["light", "dark"]) {
  for (const [size, options] of Object.entries(SIZES)) {
    const shots = Object.entries(SHOTS).filter(([name, [s]]) => s === size && (only.length === 0 || only.includes(name)));
    if (shots.length === 0) continue;
    const context = await browser.newContext({ ...options, colorScheme: scheme, locale: "ar-SA", timezoneId: "Asia/Riyadh", reducedMotion: "reduce" });
    await context.addInitScript(prepare, NOW);
    // The API, played by the demo data; Apple's sign-in script is not needed.
    await context.route(/workers\.dev|api\.zimam\.app/, (route) => {
      const { status, body } = answer(route.request().method(), route.request().url());
      route.fulfill({ status, contentType: "application/json", headers: { "access-control-allow-origin": "*" }, body: JSON.stringify(body) });
    });
    await context.route(/appleid\.cdn-apple\.com/, (route) => route.abort());
    const page = await context.newPage();
    page.on("pageerror", (error) => console.warn(`  ${scheme} ${size}: ${error.message}`));
    for (const [name, [, route, act]] of shots) {
      await page.goto("about:blank");
      await page.goto(base + route);
      await page.waitForSelector("#view h1", { state: "attached" });
      if (SAFE_AREA[size]) await page.addStyleTag({ content: SAFE_AREA[size] });
      await page.waitForTimeout(600);
      if (act) await act(page);
      await page.waitForTimeout(500);
      await page.evaluate(asSafari, Boolean(DEVICES[size]));
      // No caret or focus ring in a picture.
      await page.evaluate(() => document.activeElement?.blur?.());
      await page.addStyleTag({ content: "*{caret-color:transparent!important}:focus,:focus-visible{outline:none!important}" });
      const shot = await page.screenshot({ type: "png" });
      const webp = await toWebp(DEVICES[size] ? await framed(size, shot) : shot);
      const file = join(out, `${name}-${scheme}.webp`);
      await writeFile(file, webp);
      total += webp.length;
      console.log(`${name}-${scheme}.webp  ${Math.round(webp.length / 1024)} KB`);
    }
    await context.close();
  }
}

await browser.close();
server.close();
console.log(`${Math.round(total / 1024)} KB in all, in public/images/screens/`);
