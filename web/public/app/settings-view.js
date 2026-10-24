// «الإعدادات» on the web (SettingsView.swift), opened from the account menu: the account card with
// the photo («تغيير الصورة»، «إزالة الصورة») and the name; «عام» (the primary calendar and the
// first day of the week); «أوقات الصلاة»; «استيراد المهام»; «الحساب والمزامنة» («مزامنة الآن»،
// «تسجيل الخروج»، «حذف الحساب» after a confirmation); and «عن زمام». Settings save through PATCH /v1/me as soon as they change.
import { avatarView, preparePhoto, rememberAvatar } from "./avatar.js";
import { api } from "./lib/api.js";
import { Button, h } from "./lib/components.js";
import { dualDateWithYear } from "./lib/dates.js";
import { icon } from "./lib/icons.js";
import { WEEKDAYS, WEEKDAY_NAMES } from "./lib/recurrence.js";

/**
 * `ctx` (from main.js): { me(), today(), saveMe({ name?, settings? }) → Promise<me>, setMe(me) (the
 * account after its photo changed), openPrayers(), sync(), signOut(), deleteAccount() → Promise,
 * announce, errorText }.
 */
export function openSettings(ctx) {
  document.getElementById("settings-dialog")?.remove();
  const close = Button({ variant: "quiet" }, "إغلاق");
  const body = h("div", { className: "prayer-body" });
  const dialog = h(
    "dialog",
    { className: "sheet settings-sheet", id: "settings-dialog", "aria-labelledby": "settings-title" },
    h("div", { className: "sheet-form" }, h("div", { className: "sheet-bar" }, h("span"), h("h2", { className: "headline sheet-bar-title", id: "settings-title" }, "الإعدادات"), close), body),
  );
  close.addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);

  const error = h("p", { className: "callout field-error", role: "alert" });
  const save = async (fields, announcement) => {
    error.textContent = "";
    try {
      await ctx.saveMe(fields);
      if (announcement) ctx.announce(announcement);
      draw();
    } catch (failure) {
      if (failure.status !== 401) error.textContent = ctx.errorText(failure);
    }
  };

  const row = (label, control, id) => h("div", { className: "form-row" }, h("label", { className: "body form-label", for: id }, label), control);
  const linkRow = (iconName, label, value, onclick) =>
    h(
      "button",
      { type: "button", className: "form-row settings-link", dataset: { focus: `link-${iconName}` }, onclick },
      h("span", { className: "settings-link-label body" }, icon(iconName), label),
      h("span", { className: "settings-link-value callout muted" }, value ?? "", icon("chevron-forward", { size: "xs" })),
    );

  // The photo (AvatarStore.swift): «تغيير الصورة» picks a file, made into a 512 px square JPEG
  // (avatar.js) and sent with PUT /v1/me/avatar; «إزالة الصورة» when there is one.
  const photoError = h("p", { className: "caption field-error", role: "alert" });
  const photoFailed = (failure) => {
    if (failure?.status === 401) return;
    photoError.textContent = failure?.code === "network" ? ctx.errorText(failure) : "تعذّر رفع الصورة. اختر صورة JPEG أو PNG.";
  };
  const picker = h("input", { type: "file", accept: "image/jpeg,image/png,image/heic,image/*", hidden: true, tabindex: "-1", "aria-hidden": "true" });
  let photoBusy = false;
  picker.addEventListener("change", async () => {
    const file = picker.files?.[0];
    picker.value = "";
    if (!file || photoBusy) return;
    photoBusy = true;
    photoError.textContent = "";
    draw();
    try {
      const photo = await preparePhoto(file);
      const me = await api.uploadAvatar(photo);
      rememberAvatar(me.avatarVersion, photo);
      ctx.setMe(me);
      ctx.announce("تغيّرت صورتك.");
    } catch (failure) {
      photoFailed(failure);
    } finally {
      photoBusy = false;
      draw();
      body.querySelector(".avatar-action")?.focus();
    }
  });
  async function removePhoto() {
    if (photoBusy) return;
    photoBusy = true;
    photoError.textContent = "";
    draw();
    try {
      ctx.setMe(await api.removeAvatar());
      ctx.announce("أُزيلت صورتك.");
    } catch (failure) {
      if (failure?.status !== 401) photoError.textContent = ctx.errorText(failure);
    } finally {
      photoBusy = false;
      draw();
      body.querySelector(".avatar-action")?.focus();
    }
  }
  function photoControls(me) {
    const change = Button({ variant: "quiet", className: "avatar-action", dataset: { focus: "photo-change" }, disabled: photoBusy, onclick: () => picker.click() }, icon("camera", { size: "sm" }), "تغيير الصورة");
    const remove = me?.avatarVersion != null ? Button({ variant: "quiet", className: "avatar-action", dataset: { focus: "photo-remove" }, disabled: photoBusy, onclick: removePhoto }, icon("trash", { size: "sm" }), "إزالة الصورة") : null;
    return [h("div", { className: "avatar-actions" }, change, remove, picker), photoError];
  }

  /** Draws the sheet again after a save; the control that has focus gets it back, and a name being typed stays. */
  function draw() {
    const active = body.contains(document.activeElement) ? document.activeElement : null;
    const focusKey = active?.id || active?.dataset.focus || null;
    const typed = active?.id === "settings-name" ? { value: active.value, start: active.selectionStart, end: active.selectionEnd } : null;
    const me = ctx.me();
    const settings = me?.settings ?? {};

    // AccountCard: the photo's letter and the name.
    const name = h("input", { className: "input body form-plain", id: "settings-name", value: me?.name ?? "", maxlength: "200", placeholder: "اسمك", "aria-label": "اسمك", autocomplete: "name" });
    name.addEventListener("change", () => {
      const value = name.value.trim();
      if (value !== (me?.name ?? "")) save({ name: value }, "حُفظ اسمك.");
    });
    const account = h(
      "div",
      { className: "account-card" },
      avatarView(me, "avatar-large title"),
      h("div", { className: "account-card-body" }, name, me?.email ? h("p", { className: "caption muted account-email" }, me.email) : null, photoControls(me)),
    );

    const calendar = h(
      "select",
      { className: "input body form-control", id: "settings-calendar" },
      [["hijri", "هجري"], ["gregorian", "ميلادي"]].map(([v, t]) => h("option", { value: v, selected: v === (settings.calendar ?? "hijri") }, t)),
    );
    calendar.addEventListener("change", () => save({ settings: { calendar: calendar.value } }, "تغيّر التقويم الأساسي."));
    const weekStart = h(
      "select",
      { className: "input body form-control", id: "settings-week" },
      WEEKDAYS.map((d, i) => h("option", { value: String(i), selected: i === (settings.weekStart ?? 0) }, WEEKDAY_NAMES[d])),
    );
    weekStart.addEventListener("change", () => save({ settings: { weekStart: Number(weekStart.value) } }, "تغيّرت بداية الأسبوع."));

    const general = h(
      "section",
      { className: "form-section", "aria-labelledby": "settings-general" },
      h("h3", { className: "caption muted form-section-title", id: "settings-general" }, "عام"),
      h("div", { className: "form-card" }, row("التقويم الأساسي", calendar, "settings-calendar"), row("بداية الأسبوع", weekStart, "settings-week")),
      h("p", { className: "caption muted form-footer" }, `اليوم ${dualDateWithYear(ctx.today(), { primary: settings.calendar ?? "hijri" })}`),
    );

    const more = h(
      "div",
      { className: "form-card" },
      linkRow("moon-star", "أوقات الصلاة", settings.location ? "موقعي الحالي" : "لم يُحدَّد الموقع", () => {
        dialog.close();
        ctx.openPrayers();
      }),
      linkRow("download", "استيراد المهام", null, () => {
        dialog.close();
        location.hash = "#/import";
      }),
    );

    // «الحساب والمزامنة»
    const syncButton = h("button", { type: "button", className: "zm-btn zm-btn-quiet form-add", dataset: { focus: "sync" } }, icon("refresh", { size: "sm" }), "مزامنة الآن");
    syncButton.addEventListener("click", async () => {
      syncButton.disabled = true;
      await ctx.sync();
      syncButton.disabled = false;
    });
    const signOut = h("button", { type: "button", className: "zm-btn zm-btn-quiet form-add", dataset: { focus: "sign-out" } }, icon("log-out", { size: "sm" }), "تسجيل الخروج");
    signOut.addEventListener("click", () => {
      dialog.close();
      ctx.signOut();
    });
    const confirm = h("div", { className: "reminder-sheet", hidden: true });
    const remove = h("button", { type: "button", className: "zm-btn zm-btn-quiet form-add danger", dataset: { focus: "delete" } }, icon("trash", { size: "sm" }), "حذف الحساب");
    remove.addEventListener("click", () => {
      const yes = Button({ variant: "secondary", className: "danger" }, "حذف الحساب");
      const no = Button({ variant: "quiet" }, "إلغاء");
      const failed = h("p", { className: "callout field-error", role: "alert" });
      no.addEventListener("click", () => {
        confirm.hidden = true;
        remove.hidden = false;
        remove.focus();
      });
      yes.addEventListener("click", async () => {
        yes.disabled = true;
        try {
          await ctx.deleteAccount();
          dialog.close();
        } catch {
          failed.textContent = "تعذّر حذف الحساب. تحقّق من الاتصال وحاول مرة أخرى.";
          yes.disabled = false;
        }
      });
      confirm.replaceChildren(
        h("p", { className: "headline" }, "حذف الحساب؟"),
        h("p", { className: "callout" }, "تُحذف مهامك ومشاريعك وتذكيراتك من خادم زمام نهائياً، ولا يمكن استرجاعها. المشروع المشترك ينتقل إلى أقدم أعضائه. حذف الحساب لا يلغي اشتراك «زمام الاحترافية»: ألغه من إعدادات حسابك في App Store."),
        failed,
        h("div", { className: "sheet-actions" }, yes, no),
      );
      confirm.hidden = false;
      remove.hidden = true;
      no.focus();
    });
    const accountSection = h(
      "section",
      { className: "form-section", "aria-labelledby": "settings-account" },
      h("h3", { className: "caption muted form-section-title", id: "settings-account" }, "الحساب والمزامنة"),
      h("div", { className: "form-card" }, syncButton, signOut, remove, confirm),
      h("p", { className: "caption muted form-footer" }, "تتزامن مهامك تلقائياً بين أجهزتك."),
    );

    const about = h(
      "section",
      { className: "form-section", "aria-labelledby": "settings-about" },
      h("h3", { className: "caption muted form-section-title", id: "settings-about" }, "عن زمام"),
      h("div", { className: "form-card" },
        h("a", { className: "form-row settings-link body", href: "/privacy/" }, h("span", { className: "settings-link-label" }, "سياسة الخصوصية"), icon("chevron-forward", { size: "xs" })),
        h("a", { className: "form-row settings-link body", href: "/terms/" }, h("span", { className: "settings-link-label" }, "شروط الاستخدام"), icon("chevron-forward", { size: "xs" }))),
    );

    body.replaceChildren(h("div", { className: "form-card" }, account), general, more, accountSection, about, error);
    if (!focusKey) return;
    const again = body.querySelector(`#${CSS.escape(focusKey)}, [data-focus="${CSS.escape(focusKey)}"]`);
    if (typed && again) {
      again.value = typed.value;
      again.setSelectionRange?.(typed.start, typed.end);
    }
    again?.focus();
  }

  draw();
  dialog.showModal();
  close.focus();
}
