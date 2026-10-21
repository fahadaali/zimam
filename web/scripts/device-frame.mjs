// Device frames for the website's screenshots (scripts/screenshots.mjs): an iPhone and an iPad
// drawn to their real proportions around a screenshot of the web app, with what the device itself
// shows over an app — the status bar (mirrored in Arabic: the time at the right, the battery and
// Wi-Fi at the left), the Dynamic Island, the home indicator — and the buttons on the frame.
// The app's screenshot is taken below the status bar, as an app lays out inside the safe area.
// The result is a transparent PNG, so the frame sits on either theme of the page.
//
// The colours here are the hardware's (titanium, glass, black bezel) and the system status bar's
// (black or white by the screen behind it), not Zimam's, so they are written here rather than
// taken from tokens.css. Sizes are points, as Apple gives them.

/** Points. `status` is the status bar's height; the app's screenshot fills the rest of the screen. */
export const DEVICES = {
  // iPhone 16 / 15: a 6.1" screen of 390×844 with the Dynamic Island.
  phone: {
    screen: { width: 390, height: 844, radius: 55 },
    bezel: 9,
    band: 3,
    status: 54,
    island: { width: 126, height: 37, top: 11 },
    homeIndicator: { width: 134, height: 5, bottom: 8 },
    // Physical left side: the Action button and the volume buttons; right side: the side button.
    buttons: [
      { side: "left", top: 126, height: 32 },
      { side: "left", top: 184, height: 60 },
      { side: "left", top: 256, height: 60 },
      { side: "right", top: 208, height: 96 },
    ],
    margin: 32,
    scale: 2,
  },
  // iPad Air 11" in landscape: 1180×820, the front camera in the long edge.
  tablet: {
    screen: { width: 1180, height: 820, radius: 18 },
    bezel: 18,
    band: 2,
    status: 24,
    camera: true,
    homeIndicator: { width: 320, height: 5, bottom: 8 },
    buttons: [],
    margin: 32,
    scale: 1.5,
  },
};

/** The viewport the app is shown in: the screen below the status bar. */
export function appViewport(device) {
  const d = DEVICES[device];
  return { width: d.screen.width, height: d.screen.height - d.status };
}

/** The whole picture's size in points, frame, buttons and shadow room included. */
export function frameSize(device) {
  const d = DEVICES[device];
  const edge = d.bezel + d.band + d.margin;
  return { width: d.screen.width + 2 * edge, height: d.screen.height + 2 * edge };
}

const SIGNAL = `<svg width="18" height="12" viewBox="0 0 18 12" aria-hidden="true"><rect x="0" y="7.5" width="3" height="4.5" rx="0.8"/><rect x="5" y="5" width="3" height="7" rx="0.8"/><rect x="10" y="2.5" width="3" height="9.5" rx="0.8"/><rect x="15" y="0" width="3" height="12" rx="0.8"/></svg>`;
const WIFI = `<svg width="16" height="12" viewBox="0 0 16 12" aria-hidden="true"><path d="M8 2.2c2.4 0 4.6.9 6.2 2.5l1.2-1.3A10.5 10.5 0 0 0 8 .4 10.5 10.5 0 0 0 .6 3.4l1.2 1.3A8.8 8.8 0 0 1 8 2.2Z"/><path d="M8 5.6c1.5 0 2.9.6 3.9 1.6l1.2-1.3A7.3 7.3 0 0 0 8 3.8a7.3 7.3 0 0 0-5.1 2.1l1.2 1.3c1-1 2.4-1.6 3.9-1.6Z"/><path d="M8 9c.7 0 1.3.3 1.8.7L8 11.6 6.2 9.7C6.7 9.3 7.3 9 8 9Z"/></svg>`;
const BATTERY = `<svg width="27" height="13" viewBox="0 0 27 13" aria-hidden="true"><rect x="0.5" y="0.5" width="23" height="12" rx="3.6" fill="none" stroke="currentColor" stroke-opacity="0.4"/><rect x="2" y="2" width="20" height="9" rx="2.2"/><path d="M25 4.4v4.2a2.2 2.2 0 0 0 0-4.2Z" fill-opacity="0.45"/></svg>`;

/**
 * The page that draws `device` around `screen` (a data: URL of the app's screenshot below the
 * status bar). `time` and `date` are what the status bar says, `font` the URL of the bold face for it.
 */
export function frameHtml(device, { screen, time, date, font }) {
  const d = DEVICES[device];
  const { width, height } = frameSize(device);
  const outer = d.screen.radius + d.bezel + d.band;
  const buttons = d.buttons
    .map((b) => `<span class="button ${b.side}" style="top:${d.margin + d.band + d.bezel + b.top}px;height:${b.height}px"></span>`)
    .join("");
  return `<!doctype html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8">
<style>
@font-face { font-family: "status"; src: url("${font}") format("woff2"); font-weight: 600; }
html, body { margin: 0; background: transparent; }
body { width: ${width}px; height: ${height}px; position: relative; }
.device {
  position: absolute; inset: ${d.margin}px;
  border-radius: ${outer}px;
  /* The titanium band, lit from above, with a fine bright rim. */
  background: linear-gradient(160deg, #6d6c6a 0%, #3a3a3c 22%, #2b2b2d 55%, #4a4948 82%, #6a6967 100%);
  box-shadow: 0 0 0 0.6px rgba(255,255,255,0.18) inset, 0 ${d.margin / 2}px ${d.margin}px rgba(0,0,0,0.22), 0 2px 6px rgba(0,0,0,0.18);
}
.bezel {
  position: absolute; inset: ${d.band}px;
  border-radius: ${outer - d.band}px;
  background: #050506;
  box-shadow: 0 0 0 0.75px rgba(0,0,0,0.9) inset;
}
.screen {
  position: absolute; inset: ${d.bezel}px;
  border-radius: ${d.screen.radius}px;
  overflow: hidden;
  background: #fff;
}
/* Under the status bar the app's own top edge continues (an iPad's sidebar runs up under it). */
.band { position: absolute; inset-inline: 0; top: 0; display: block; width: ${d.screen.width}px; height: ${d.status}px; }
.app { position: absolute; inset-inline: 0; top: ${d.status}px; display: block; width: ${d.screen.width}px; height: ${d.screen.height - d.status}px; }
/* The status bar, mirrored as iOS draws it in Arabic. */
.status {
  position: absolute; inset-inline: 0; top: 0; height: ${d.status}px;
  display: flex; align-items: center; justify-content: space-between;
  padding-inline: ${device === "phone" ? 34 : 22}px;
  padding-block-start: ${device === "phone" ? 6 : 0}px;
  box-sizing: border-box;
  color: var(--status-ink, #000);
  font: 600 ${device === "phone" ? 17 : 14}px/1 "status", system-ui, sans-serif;
}
.status .time { display: flex; gap: 6px; min-width: ${device === "phone" ? 54 : 0}px; justify-content: center; }
.status .icons { display: flex; flex-direction: row-reverse; align-items: center; gap: 6px; direction: ltr; }
.status svg { fill: currentColor; display: block; }
.island {
  position: absolute; top: ${d.island?.top ?? 0}px; left: 50%; transform: translateX(-50%);
  width: ${d.island?.width ?? 0}px; height: ${d.island?.height ?? 0}px; border-radius: 999px; background: #000;
}
.island::after {
  /* The front camera's lens, just visible in the island. */
  content: ""; position: absolute; right: 26px; top: 50%; width: 11px; height: 11px; margin-top: -5.5px;
  border-radius: 50%; background: radial-gradient(circle at 35% 35%, #2a3550 0%, #0b0e18 60%, #000 100%);
}
.camera {
  position: absolute; left: 50%; top: ${d.band + d.bezel / 2}px; width: 6px; height: 6px; margin: -3px 0 0 -3px;
  border-radius: 50%; background: radial-gradient(circle at 35% 35%, #2c3550, #07080c 70%);
}
.home {
  position: absolute; left: 50%; transform: translateX(-50%);
  bottom: ${d.homeIndicator.bottom}px; width: ${d.homeIndicator.width}px; height: ${d.homeIndicator.height}px;
  border-radius: 999px; background: var(--status-ink, #000);
}
/* A faint sheen across the glass. */
.screen::after {
  content: ""; position: absolute; inset: 0; pointer-events: none; border-radius: inherit;
  background: linear-gradient(115deg, rgba(255,255,255,0.06) 0%, rgba(255,255,255,0) 38%);
}
.button {
  position: absolute; width: 3px; border-radius: 2px;
  background: linear-gradient(90deg, #2a2a2c, #58575a 50%, #2a2a2c);
}
.button.left { left: ${d.margin - 2.5}px; }
.button.right { right: ${d.margin - 2.5}px; }
</style></head>
<body>
${buttons}
<div class="device">
  <div class="bezel">
    <div class="screen">
      <canvas class="band"></canvas>
      <img class="app" src="${screen}" alt="">
      <div class="status">
        <span class="time"><span>${time}</span>${date ? `<span>${date}</span>` : ""}</span>
        <span class="icons">${device === "phone" ? SIGNAL : ""}${WIFI}${BATTERY}</span>
      </div>
      ${d.island ? `<div class="island"></div>` : ""}
      <div class="home"></div>
    </div>
  </div>
  ${d.camera ? `<div class="camera"></div>` : ""}
</div>
<script>
// Under the status bar, the app's first row of pixels drawn down to the top of the screen; the
// status bar's text is black or white by the colour there.
const img = document.querySelector(".app");
img.decode().then(() => {
  const band = document.querySelector(".band");
  band.width = img.naturalWidth;
  band.height = Math.round((img.naturalWidth / ${d.screen.width}) * ${d.status});
  const ctx = band.getContext("2d");
  ctx.drawImage(img, 0, 0, img.naturalWidth, 1, 0, 0, band.width, band.height);
  const [r, g, b] = ctx.getImageData(Math.floor(band.width / 2), 0, 1, 1).data;
  const light = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 > 0.5;
  document.documentElement.style.setProperty("--status-ink", light ? "#000" : "#fff");
  document.body.dataset.ready = "1";
});
</script>
</body></html>`;
}
