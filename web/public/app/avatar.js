// The account photo on the web (AvatarStore.swift): read once per `avatarVersion` with the session
// (GET /v1/me/avatar) and shown from an object URL, which the CSP allows as img-src blob:; the
// name's first letter while it loads and when there is none. Choosing a photo makes the middle
// square at 512 px as JPEG (lib/avatar.js) before PUT /v1/me/avatar.
import { api } from "./lib/api.js";
import { MAX_AVATAR_BYTES, encodeWithin, squareCrop } from "./lib/avatar.js";
import { h } from "./lib/components.js";
import { avatarInitial } from "./lib/sharing.js";

/** One photo for this page's life: its version, object URL, and the read in flight. */
const cache = { version: null, url: null, loading: null };

function keep(version, blob) {
  if (cache.url) URL.revokeObjectURL(cache.url);
  cache.version = version;
  cache.url = blob ? URL.createObjectURL(blob) : null;
  cache.loading = null;
  return cache.url;
}

/** The photo's object URL for `version`, or null when there is none or it cannot be read. */
export function avatarUrl(version) {
  if (version == null) {
    if (cache.version != null) keep(null, null);
    return Promise.resolve(null);
  }
  if (cache.version === version && !cache.loading) return Promise.resolve(cache.url);
  if (cache.version === version && cache.loading) return cache.loading;
  if (cache.url) URL.revokeObjectURL(cache.url);
  cache.version = version;
  cache.url = null;
  // The version in the query keeps the browser's cache (max-age a day) from answering an old photo.
  const loading = api
    .avatar(version)
    .then((blob) => (cache.loading === loading ? keep(version, blob) : null))
    .catch(() => (cache.loading === loading ? keep(version, null) : null));
  cache.loading = loading;
  return loading;
}

/** After an upload: the bytes just sent are the photo of the new version, with no read back. */
export function rememberAvatar(version, blob) {
  if (version != null) keep(version, blob);
}

/**
 * The `.avatar` circle for `me`: the photo when there is one (alt="", the name is beside it or in
 * the button's label), else the initial. `className` adds the size and type classes.
 */
export function avatarView(me, className = "callout") {
  const initial = avatarInitial(me?.name);
  const el = h("span", { className: `avatar ${className}`, "aria-hidden": "true" }, initial);
  const version = me?.avatarVersion ?? null;
  const show = (url) => {
    if (!url) return;
    const img = h("img", { src: url, alt: "", decoding: "async" });
    img.addEventListener("error", () => el.replaceChildren(initial));
    el.replaceChildren(img);
  };
  if (version == null) return el;
  if (cache.version === version && cache.url && !cache.loading) show(cache.url);
  else avatarUrl(version).then(show);
  return el;
}

/** Loads a chosen file into an <img>, which applies the photo's orientation (and reads HEIC in Safari). */
function loadImage(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => resolve({ img, done: () => URL.revokeObjectURL(url) });
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("unreadable image"));
    };
    img.src = url;
  });
}

/** The chosen file as the photo to upload: a square JPEG of at most 512 px under 1 MB, or an Error. */
export async function preparePhoto(file) {
  const { img, done } = await loadImage(file);
  try {
    const crop = squareCrop(img.naturalWidth, img.naturalHeight);
    if (!crop.side) throw new Error("empty image");
    const canvas = document.createElement("canvas");
    canvas.width = crop.side;
    canvas.height = crop.side;
    const context = canvas.getContext("2d");
    // JPEG has no transparency: a transparent PNG sits on the avatar's own background.
    context.fillStyle = getComputedStyle(document.documentElement).getPropertyValue("--brand-soft").trim() || "transparent";
    context.fillRect(0, 0, crop.side, crop.side);
    context.imageSmoothingQuality = "high";
    context.drawImage(img, crop.sx, crop.sy, crop.edge, crop.edge, 0, 0, crop.side, crop.side);
    const blob = await encodeWithin((quality) => new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", quality)), { maxBytes: MAX_AVATAR_BYTES });
    if (!blob) throw new Error("photo too large");
    return blob;
  } finally {
    done();
  }
}
