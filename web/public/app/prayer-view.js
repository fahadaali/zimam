// Prayer times on the web, from GET /v1/prayers (the apps compute them on the device):
// - NextPrayerLine on «اليوم»: «العصر بعد ١:١٢:٠٥», or «مضى على أذان العصر ١٢:٠٣» for half an
//   hour after it, in sand on sand-soft; it opens «أوقات الصلاة».
// - «أوقات الصلاة» (PrayerTimesView.swift): the clock card, «مواقيت اليوم» with the sunrise,
//   «الموقع» and «الحساب». Adhan and iqama alerts are the devices' own, set in the app.
// - The clock time of a prayer-anchored task on its day, for its chip («٢:٥٠ م»).
import { request } from "./lib/api.js";
import { Button, h } from "./lib/components.js";
import { addDays, dualDateWithYear, timeLabel } from "./lib/dates.js";
import { icon } from "./lib/icons.js";
import { MADHAB_NAMES, METHOD_NAMES, clockIn, clockState, prayerInstant, timerText } from "./lib/prayer-clock.js";
import { PRAYERS, PRAYER_NAMES, prayerPhrase } from "./lib/prayer.js";

/** Days read at once: today and the month ahead, for the chips of the coming tasks. */
const SPAN = 30;

/**
 * `ctx` (from main.js): { me(), today(), primary(), saveSettings(settings) → Promise<me>,
 * announce, errorText, onChange() } — onChange redraws the view once the times arrive or change.
 */
export function createPrayers(ctx) {
  let cache = { key: null, days: [], timeZone: null, location: null, loading: null };

  const keyOf = () => {
    const s = ctx.me()?.settings ?? {};
    return JSON.stringify([ctx.today(), s.location, s.prayerMethod, s.asrMadhab, s.timeZone]);
  };

  /** Reads the times when the day or the settings changed; redraws the view once they arrive. */
  function load({ force = false } = {}) {
    const key = keyOf();
    if (!force && (cache.key === key || cache.loading)) return cache.loading ?? Promise.resolve();
    const from = ctx.today();
    cache.loading = request("GET", `/v1/prayers?from=${from}&to=${addDays(from, SPAN)}`)
      .then((answer) => {
        const changed = JSON.stringify(answer.days) !== JSON.stringify(cache.days);
        cache = { key, days: answer.days ?? [], timeZone: answer.timeZone, location: answer.location, loading: null };
        if (changed) ctx.onChange();
      })
      .catch(() => {
        cache.loading = null; // an older server without the route, or offline: phrases stay
      });
    return cache.loading;
  }

  const hasLocation = () => !!ctx.me()?.settings?.location;

  /** The chip for a task at a prayer: its clock time on the task's day, the phrase for screen readers. */
  function chipFor(task) {
    const phrase = prayerPhrase(task.duePrayer, task.duePrayerOffset);
    if (!phrase) return null;
    const at = prayerInstant(cache.days, task.dueDate ?? ctx.today(), task.duePrayer, task.duePrayerOffset ?? 0);
    if (at == null || !cache.timeZone) return { text: phrase };
    return { text: timeLabel(clockIn(at, cache.timeZone)), spoken: phrase };
  }

  // ——— «العصر بعد ١:١٢:٠٥» ———

  function nextLine() {
    const text = h("span", { className: "prayer-line-text" });
    const button = h(
      "button",
      { type: "button", className: "prayer-line callout", "aria-haspopup": "dialog" },
      icon("moon-star", { size: "sm" }),
      text,
      icon("chevron-forward", { size: "xs" }),
    );
    button.addEventListener("click", openSheet);
    let timer = null;
    const draw = () => {
      if (!button.isConnected && timer) {
        clearInterval(timer);
        return;
      }
      if (!hasLocation()) {
        text.textContent = "حدّد موقعك لتظهر أوقات الصلاة";
        return;
      }
      const state = clockState(cache.days, Date.now());
      if (!state) {
        text.textContent = "أوقات الصلاة";
        return;
      }
      const name = PRAYER_NAMES[state.prayer];
      text.replaceChildren(
        state.kind === "since" ? `مضى على أذان ${name} ` : `${name} بعد `,
        h("span", { className: "timer" }, timerText(Date.now() - state.at)),
      );
    };
    draw();
    // Once a second, as the app's timer; it stops when Today is left.
    timer = setInterval(draw, 1000);
    return button;
  }

  // ——— «أوقات الصلاة» ———

  let sheet = null;

  function openSheet() {
    sheet?.remove();
    const body = h("div", { className: "prayer-body" });
    const close = Button({ variant: "quiet" }, "إغلاق");
    sheet = h(
      "dialog",
      { className: "sheet prayer-sheet", "aria-labelledby": "prayer-sheet-title" },
      h("div", { className: "sheet-form" }, h("div", { className: "sheet-bar" }, h("span"), h("h2", { className: "headline sheet-bar-title", id: "prayer-sheet-title" }, "أوقات الصلاة"), close), body),
    );
    close.addEventListener("click", () => sheet.close());
    sheet.addEventListener("close", () => {
      clearInterval(tick);
      sheet.remove();
      sheet = null;
    });
    document.body.append(sheet);
    const draw = () => body.replaceChildren(...sections());
    draw();
    const tick = setInterval(() => {
      const clock = body.querySelector(".prayer-clock");
      if (clock) clock.replaceWith(clockCard());
    }, 1000);
    sheet.showModal();
    close.focus();
    load().then(() => sheet && draw());
    redrawSheet = draw;
  }

  let redrawSheet = () => {};

  function clockCard() {
    const state = clockState(cache.days, Date.now());
    if (!state) return h("div", { className: "prayer-clock" });
    const name = PRAYER_NAMES[state.prayer];
    return h(
      "div",
      { className: "prayer-clock", role: "group", "aria-label": state.kind === "since" ? `مضى على أذان ${name}` : `المتبقي على ${name}` },
      h("p", { className: "callout" }, state.kind === "since" ? `مضى على أذان ${name}` : `المتبقي على ${name}`),
      h("p", { className: "display timer", "aria-hidden": "true" }, timerText(Date.now() - state.at)),
      h("p", { className: "callout" }, `${name}، ${timeLabel(clockIn(state.at, cache.timeZone))}`),
    );
  }

  function sections() {
    const out = [];
    if (hasLocation() && cache.days.length) {
      out.push(clockCard());
      const today = cache.days.find((d) => d.date === ctx.today()) ?? cache.days[0];
      const next = clockState(cache.days, Date.now());
      const rows = ["fajr", "sunrise", ...PRAYERS.slice(1)].map((p) => {
        const isNext = next?.kind === "until" && next.prayer === p && next.at === today.times[p]?.at;
        return h(
          "li",
          { className: `prayer-row${isNext ? " is-next" : ""}` },
          h("span", { className: isNext ? "headline" : "body" }, p === "sunrise" ? "الشروق" : PRAYER_NAMES[p]),
          isNext ? h("span", { className: "caption prayer-next" }, "القادمة") : null,
          h("span", { className: isNext ? "headline prayer-time" : "body prayer-time" }, timeLabel(today.times[p].time)),
        );
      });
      out.push(
        h("section", { className: "form-section", "aria-labelledby": "today-times" },
          h("h3", { className: "caption muted form-section-title", id: "today-times" }, "مواقيت اليوم"),
          h("p", { className: "caption muted form-footer" }, dualDateWithYear(today.date, { primary: ctx.primary() })),
          h("ul", { className: "prayer-rows", role: "list" }, rows)),
      );
    }
    out.push(locationSection(), calculationSection());
    out.push(h("p", { className: "caption muted" }, "تنبيهات الأذان والإقامة تُضبط من تطبيق زمام على أجهزتك."));
    return out;
  }

  function locationSection() {
    const status = h("p", { className: "caption muted form-footer", role: "status" });
    const use = h("button", { type: "button", className: "zm-btn zm-btn-quiet form-add" }, icon("pin", { size: "sm" }), hasLocation() ? "تحديث موقعي" : "استعمال موقعي الحالي");
    use.addEventListener("click", () => {
      if (!("geolocation" in navigator)) {
        status.textContent = "المتصفح لا يتيح تحديد الموقع.";
        return;
      }
      use.disabled = true;
      status.textContent = "يحدّد المتصفح موقعك…";
      navigator.geolocation.getCurrentPosition(
        async ({ coords }) => {
          // The city is enough for prayer times: two decimals, about a kilometre.
          const round = (n) => Math.round(n * 100) / 100;
          try {
            await ctx.saveSettings({ location: { latitude: round(coords.latitude), longitude: round(coords.longitude) }, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone });
            ctx.announce("حُفظ موقعك لأوقات الصلاة.");
            await load({ force: true });
            redrawSheet();
          } catch (failure) {
            status.textContent = ctx.errorText(failure);
          } finally {
            use.disabled = false;
          }
        },
        (failure) => {
          use.disabled = false;
          status.textContent = failure.code === 1 ? "لم يُسمح بتحديد الموقع. اسمح به لهذا الموقع من إعدادات المتصفح." : "تعذّر تحديد موقعك. حاول مرة أخرى.";
        },
        { enableHighAccuracy: false, timeout: 15_000, maximumAge: 600_000 },
      );
    });
    const place = hasLocation()
      ? h("div", { className: "form-row" }, h("span", { className: "body" }, "المكان"), h("span", { className: "body" }, "موقعي الحالي"))
      : h("p", { className: "callout form-note" }, "لا موقع محفوظ بعد.");
    return h(
      "section",
      { className: "form-section", "aria-labelledby": "prayer-location" },
      h("h3", { className: "caption muted form-section-title", id: "prayer-location" }, "الموقع"),
      h("div", { className: "form-card" }, place, use),
      h("p", { className: "caption muted form-footer" }, "تُحسب الأوقات لموقعك على مستوى المدينة، والتطبيق يحدّثه حين تتنقّل."),
      status,
    );
  }

  function calculationSection() {
    const settings = ctx.me()?.settings ?? {};
    const error = h("p", { className: "caption field-error form-footer", role: "alert" });
    const select = (id, label, names, value, key) => {
      const el = h(
        "select",
        { className: "input body form-control", id },
        Object.entries(names).map(([v, t]) => h("option", { value: v, selected: v === value }, t)),
      );
      el.addEventListener("change", async () => {
        error.textContent = "";
        try {
          await ctx.saveSettings({ [key]: el.value });
          await load({ force: true });
          redrawSheet();
        } catch {
          error.textContent = "تعذّر حفظ الإعدادات. تحقّق من الاتصال وحاول مرة أخرى.";
        }
      });
      return h("div", { className: "form-row" }, h("label", { className: "body form-label", for: id }, label), el);
    };
    return h(
      "section",
      { className: "form-section", "aria-labelledby": "prayer-calc" },
      h("h3", { className: "caption muted form-section-title", id: "prayer-calc" }, "الحساب"),
      h("div", { className: "form-card" },
        select("prayer-method", "طريقة الحساب", METHOD_NAMES, settings.prayerMethod ?? "ummAlQura", "prayerMethod"),
        select("prayer-madhab", "وقت العصر", MADHAB_NAMES, settings.asrMadhab ?? "shafi", "asrMadhab")),
      h("p", { className: "caption muted form-footer" }, "الجمهور: العصر حين يصير ظل الشيء مثله. الحنفي: حين يصير مثليه."),
      error,
    );
  }

  return { load, chipFor, nextLine, openSheet, hasLocation };
}
