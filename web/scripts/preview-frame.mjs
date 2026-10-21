// The live preview's page (scripts/preview.mjs): the web app running inside an iPhone, drawn to
// the proportions device-frame.mjs gives the website's screenshots, with the theme and a reset
// beside it. Written as an Artifact page: the host wraps it in <html>, <head> and <body>.
//
// Wide windows show the whole phone scaled to fit; at phone width the screen alone fills the
// window at its real size, since the viewer is then holding a phone already.
//
// The device's colours (titanium, glass, black bezel) and its status bar's are the hardware's, so
// they are written here as device-frame.mjs writes them; everything around the phone takes
// tokens.css. The device is drawn left to right, as the hardware is, and its status bar mirrored as
// iOS draws it in Arabic (the time at the right).
import { DEVICES } from "./device-frame.mjs";

// The status bar's icons, as device-frame.mjs draws them.
const SIGNAL = `<svg width="18" height="12" viewBox="0 0 18 12" aria-hidden="true"><rect x="0" y="7.5" width="3" height="4.5" rx="0.8"/><rect x="5" y="5" width="3" height="7" rx="0.8"/><rect x="10" y="2.5" width="3" height="9.5" rx="0.8"/><rect x="15" y="0" width="3" height="12" rx="0.8"/></svg>`;
const WIFI = `<svg width="16" height="12" viewBox="0 0 16 12" aria-hidden="true"><path d="M8 2.2c2.4 0 4.6.9 6.2 2.5l1.2-1.3A10.5 10.5 0 0 0 8 .4 10.5 10.5 0 0 0 .6 3.4l1.2 1.3A8.8 8.8 0 0 1 8 2.2Z"/><path d="M8 5.6c1.5 0 2.9.6 3.9 1.6l1.2-1.3A7.3 7.3 0 0 0 8 3.8a7.3 7.3 0 0 0-5.1 2.1l1.2 1.3c1-1 2.4-1.6 3.9-1.6Z"/><path d="M8 9c.7 0 1.3.3 1.8.7L8 11.6 6.2 9.7C6.7 9.3 7.3 9 8 9Z"/></svg>`;
const BATTERY = `<svg width="27" height="13" viewBox="0 0 27 13" aria-hidden="true"><rect x="0.5" y="0.5" width="23" height="12" rx="3.6" fill="none" stroke="currentColor" stroke-opacity="0.4"/><rect x="2" y="2" width="20" height="9" rx="2.2"/><path d="M25 4.4v4.2a2.2 2.2 0 0 0 0-4.2Z" fill-opacity="0.45"/></svg>`;

/**
 * The bottom safe area the iPhone gives the app, which the frame's iframe reports as 0: the rules
 * scripts/screenshots.mjs adds for the phone, with the home indicator's 34pt in them.
 */
const SAFE_AREA = `.tabbar{padding-block-end:34px!important}
.fab{inset-block-end:calc(var(--tabbar) + var(--space-4) + 34px)!important}
.sheet{padding-block-end:34px!important}`;

/** The page, for the app at `app` (its index.html, relative to the page) opening on `route`. */
export function previewPage({ app = "app/index.html", route = "#/today" } = {}) {
  const d = DEVICES.phone;
  const outer = d.screen.radius + d.bezel + d.band;
  const width = d.screen.width + 2 * (d.bezel + d.band);
  const height = d.screen.height + 2 * (d.bezel + d.band);
  const buttons = d.buttons.map((b) => `<span class="hw-button ${b.side === "left" ? "start" : "end"}" style="inset-block-start:${d.band + d.bezel + b.top}px;height:${b.height}px"></span>`).join("");

  return `<title>معاينة زمام</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="stylesheet" href="design/generated/tokens.css">
<style>
/* Layout: a bar of controls, then the phone centred below it and scaled to the room left. */
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { color-scheme: dark; } }
:root[data-theme="dark"] { color-scheme: dark; }
html, body { height: 100%; }
body {
  margin: 0; display: flex; flex-direction: column;
  background: var(--surface-sunken); color: var(--ink); font-family: var(--font-sans);
}
.bar {
  display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: var(--space-3);
  padding-block: var(--space-3);
  padding-left: max(16px, env(safe-area-inset-left, 0px));
  padding-right: max(16px, env(safe-area-inset-right, 0px));
}
.bar h1, .bar p { margin: 0; }
.muted { color: var(--ink-muted); }
.actions { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2); }
.segmented {
  display: flex; border: 1px solid var(--line-strong); border-radius: var(--radius-md);
  background: var(--surface-raised); overflow: hidden; margin: 0; padding: 0;
}
.segmented label { position: relative; display: grid; place-items: center; min-height: var(--space-11); padding-inline: var(--space-3); cursor: pointer; }
.segmented label + label { border-inline-start: 1px solid var(--line); }
.segmented input { position: absolute; opacity: 0; inset: 0; margin: 0; cursor: pointer; }
.segmented label:has(input:checked) { background: var(--brand-soft); color: var(--brand-ink); }
.segmented label:has(input:focus-visible) { outline: 2px solid var(--focus-ring); outline-offset: -2px; }
.reset {
  min-height: var(--space-11); padding-inline: var(--space-4); border-radius: var(--radius-md);
  border: 1px solid var(--line-strong); background: var(--surface-raised); color: var(--ink); font: inherit; cursor: pointer;
}
.reset:active { opacity: var(--opacity-pressed); }
.reset:focus-visible { outline: 2px solid var(--focus-ring); outline-offset: 2px; }

.stage {
  flex: 1; min-height: 0; display: flex; justify-content: center; align-items: flex-start;
  padding-block: var(--space-2) var(--space-6);
  padding-left: max(16px, env(safe-area-inset-left, 0px));
  padding-right: max(16px, env(safe-area-inset-right, 0px));
}
.sizer { position: relative; width: calc(${width}px * var(--s, 1)); height: calc(${height}px * var(--s, 1)); }
.device {
  position: relative; direction: ltr; width: ${width}px; height: ${height}px;
  margin-inline: calc((${width}px * var(--s, 1) - ${width}px) / 2);
  transform: scale(var(--s, 1)); transform-origin: top center;
  border-radius: ${outer}px;
  /* The titanium band, lit from above, with a fine bright rim. */
  background: linear-gradient(160deg, #6d6c6a 0%, #3a3a3c 22%, #2b2b2d 55%, #4a4948 82%, #6a6967 100%);
  box-shadow: 0 0 0 0.6px rgba(255,255,255,0.18) inset, 0 16px 32px rgba(0,0,0,0.22), 0 2px 6px rgba(0,0,0,0.18);
}
.hw-button { position: absolute; width: 3px; border-radius: 2px; background: linear-gradient(90deg, #2a2a2c, #58575a 50%, #2a2a2c); }
.hw-button.start { inset-inline-start: -2.5px; }
.hw-button.end { inset-inline-end: -2.5px; }
.bezel { position: absolute; inset: ${d.band}px; border-radius: ${outer - d.band}px; background: #050506; }
.screen { position: absolute; inset: ${d.bezel}px; border-radius: ${d.screen.radius}px; overflow: hidden; background: var(--surface); isolation: isolate; }
.status {
  position: absolute; inset-inline: 0; inset-block-start: 0; height: ${d.status}px; z-index: 1;
  display: flex; align-items: center; justify-content: space-between; direction: rtl;
  padding-inline: 34px; padding-block-start: 6px; box-sizing: border-box;
  background: var(--status-band, var(--surface)); color: var(--status-ink, #000);
  font: 600 17px/1 var(--font-sans);
}
.status .time { min-width: 54px; text-align: center; font-variant-numeric: tabular-nums; }
.status .icons { display: flex; flex-direction: row-reverse; align-items: center; gap: 6px; direction: ltr; }
.status svg { fill: currentColor; display: block; }
.island {
  position: absolute; z-index: 2; inset-block-start: ${d.island.top}px; inset-inline-start: calc(50% - ${d.island.width / 2}px);
  width: ${d.island.width}px; height: ${d.island.height}px; border-radius: 999px; background: #000;
}
.island::after {
  /* The front camera's lens, just visible in the island. */
  content: ""; position: absolute; inset-inline-end: 26px; inset-block-start: calc(50% - 5.5px); width: 11px; height: 11px;
  border-radius: 50%; background: radial-gradient(circle at 35% 35%, #2a3550 0%, #0b0e18 60%, #000 100%);
}
.app { position: absolute; inset-inline: 0; inset-block-start: ${d.status}px; width: ${d.screen.width}px; height: ${d.screen.height - d.status}px; border: 0; display: block; background: var(--surface); }
.home {
  position: absolute; z-index: 2; inset-inline-start: calc(50% - ${d.homeIndicator.width / 2}px); inset-block-end: ${d.homeIndicator.bottom}px;
  width: ${d.homeIndicator.width}px; height: ${d.homeIndicator.height}px; border-radius: 999px; background: var(--status-ink, #000);
  pointer-events: none;
}

/* At phone width: the screen alone, full width and full height, at its real size. */
body[data-bare] .stage { padding: 0; padding-left: env(safe-area-inset-left, 0px); padding-right: env(safe-area-inset-right, 0px); align-items: stretch; }
body[data-bare] .sizer { width: 100%; height: auto; }
body[data-bare] .device { width: 100%; height: 100%; margin: 0; transform: none; border-radius: 0; background: none; box-shadow: none; }
body[data-bare] .bezel, body[data-bare] .screen { inset: 0; border-radius: 0; }
body[data-bare] .status, body[data-bare] .island, body[data-bare] .home, body[data-bare] .hw-button { display: none; }
body[data-bare] .app { inset: 0; width: 100%; height: 100%; }
</style>

<header class="bar">
  <div>
    <h1 class="headline">معاينة زمام</h1>
    <p class="caption muted">نسخة الويب ببيانات تجريبية، وما تغيّره فيها يبقى حتى تعيد البيانات.</p>
  </div>
  <div class="actions">
    <fieldset class="segmented callout" aria-label="مظهر الجهاز">
      <label><input type="radio" name="theme" id="theme-auto" value="auto" checked>تلقائي</label>
      <label><input type="radio" name="theme" id="theme-light" value="light">فاتح</label>
      <label><input type="radio" name="theme" id="theme-dark" value="dark">داكن</label>
    </fieldset>
    <button type="button" class="reset callout" id="reset">إعادة البيانات</button>
  </div>
</header>

<main class="stage" id="stage">
  <div class="sizer" id="sizer">
    <div class="device">
      ${buttons}
      <div class="bezel">
        <div class="screen">
          <div class="status" aria-hidden="true"><span class="time" id="status-time"></span><span class="icons">${SIGNAL}${WIFI}${BATTERY}</span></div>
          <div class="island"></div>
          <iframe class="app" id="app" title="تطبيق زمام" src="${app}${route}"></iframe>
          <div class="home"></div>
        </div>
      </div>
    </div>
  </div>
</main>

<script>
(() => {
  const W = ${width}, H = ${height};
  const SAFE_AREA = ${JSON.stringify(SAFE_AREA)};
  const root = document.documentElement;
  const stage = document.getElementById("stage");
  const sizer = document.getElementById("sizer");
  const frame = document.getElementById("app");
  const clock = document.getElementById("status-time");
  const narrow = matchMedia("(max-width: 32rem)");
  const systemDark = matchMedia("(prefers-color-scheme: dark)");
  let choice = "auto";
  try { choice = localStorage.getItem("zimam.preview.theme") || "auto"; } catch {}
  const radio = document.getElementById("theme-" + choice);
  if (radio) radio.checked = true; else choice = "auto";

  const appDoc = () => { try { return frame.contentDocument; } catch { return null; } };
  const bare = () => narrow.matches;

  // The whole phone in the room below the bar, never larger than its real size.
  function fit() {
    document.body.toggleAttribute("data-bare", bare());
    if (bare()) { sizer.style.removeProperty("--s"); return; }
    const style = getComputedStyle(stage);
    const roomW = stage.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    const roomH = stage.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
    sizer.style.setProperty("--s", String(Math.max(0.3, Math.min(1, roomW / W, roomH / H))));
  }

  // The theme on the phone: the one chosen, or the page's own (the viewer's or the system's).
  function theme() {
    if (choice !== "auto") return choice;
    return root.dataset.theme === "dark" || root.dataset.theme === "light" ? root.dataset.theme : systemDark.matches ? "dark" : "light";
  }

  // The status bar continues the app's own top edge, its text black or white by that colour.
  function paintStatus() {
    const doc = appDoc();
    if (!doc || !doc.body) return;
    const bg = getComputedStyle(doc.body).backgroundColor;
    const rgb = (bg.match(/[\\d.]+/g) || ["255", "255", "255"]).slice(0, 3).map(Number);
    const light = (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255 > 0.5;
    sizer.style.setProperty("--status-band", bg);
    sizer.style.setProperty("--status-ink", light ? "#000" : "#fff");
  }

  function applyTheme() {
    const doc = appDoc();
    if (doc && doc.documentElement) doc.documentElement.dataset.theme = theme();
    requestAnimationFrame(paintStatus);
  }

  // The status bar's time, from the app's own clock (the demo's morning, running).
  const timeFormat = new Intl.DateTimeFormat("ar-SA-u-nu-arab", { hour: "numeric", minute: "2-digit", hour12: true });
  function tick() {
    const AppDate = (frame.contentWindow && frame.contentWindow.Date) || Date;
    clock.textContent = timeFormat.formatToParts(new AppDate()).filter((p) => p.type === "hour" || p.type === "minute" || p.type === "literal").map((p) => p.value).join("").trim();
  }

  frame.addEventListener("load", () => {
    const doc = appDoc();
    if (doc && !bare()) {
      const style = doc.createElement("style");
      style.textContent = SAFE_AREA;
      doc.head.append(style);
    }
    applyTheme();
    tick();
    setTimeout(paintStatus, 600);
  });

  for (const input of document.querySelectorAll('input[name="theme"]')) {
    input.addEventListener("change", () => {
      choice = input.value;
      try { localStorage.setItem("zimam.preview.theme", choice); } catch {}
      applyTheme();
    });
  }
  document.getElementById("reset").addEventListener("click", () => {
    const win = frame.contentWindow;
    if (!win) return;
    win.location.hash = ${JSON.stringify(route)};
    win.location.reload();
  });

  new MutationObserver(applyTheme).observe(root, { attributes: true, attributeFilter: ["data-theme"] });
  systemDark.addEventListener("change", applyTheme);
  narrow.addEventListener("change", () => { fit(); frame.contentWindow && frame.contentWindow.location.reload(); });
  addEventListener("resize", fit);
  fit();
  setInterval(tick, 10000);
})();
</script>
`;
}
