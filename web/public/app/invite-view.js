// #/join/<code>: an invite to a shared project, opened from the join page (/join/#<code>).
// Shows what the invite offers (GET /v1/invites/:code), then joins (POST /v1/invites/:code/accept)
// and opens the project. Sign-in comes first: the route survives Apple's popup in the hash, and
// rememberPendingJoin() keeps it through Google's whole-tab sign-in.
// Plain DOM through h() and textContent; nothing here parses HTML.
import { errorText, request } from "./lib/api.js";
import { Button, ButtonLink, h } from "./lib/components.js";
import { jobDate } from "./lib/imports.js";
import { PENDING_JOIN_KEY, appJoinHash, inviteErrorText, isInviteCode, roleDescription, roleName } from "./lib/invites.js";

const invitesApi = {
  preview: (code) => request("GET", `/v1/invites/${encodeURIComponent(code)}`),
  accept: (code) => request("POST", `/v1/invites/${encodeURIComponent(code)}/accept`),
};

const problemText = (error) => inviteErrorText(error?.code) ?? errorText(error);

/** Before sign-in: keeps the invite so the app can return to it once signed in. */
export function rememberPendingJoin(code) {
  if (!isInviteCode(code)) return;
  try {
    sessionStorage.setItem(PENDING_JOIN_KEY, code);
  } catch {
    /* storage blocked: the hash still carries it through Apple's popup */
  }
}

/** After sign-in: the hash of a remembered invite, once. */
export function takePendingJoin() {
  let code = null;
  try {
    code = sessionStorage.getItem(PENDING_JOIN_KEY);
    sessionStorage.removeItem(PENDING_JOIN_KEY);
  } catch {
    return null;
  }
  return isInviteCode(code) ? appJoinHash(code) : null;
}

/**
 * The view. `ctx`: { code, primary, today, timeZone, announce(text), onJoined(projectId) } from main.js.
 * Returns its nodes, like the other views.
 */
export async function viewJoin(ctx) {
  const header = h(
    "header",
    { className: "view-header" },
    h("h1", { className: "display view-title", tabindex: "-1" }, "دعوة إلى مشروع"),
    h("p", { className: "callout muted" }, "دعاك مالك المشروع لتشاركه مهامه. راجع الدعوة ثم انضم."),
  );
  const back = ButtonLink({ variant: "quiet", href: "#/projects" }, "المشاريع");

  if (!isInviteCode(ctx.code)) {
    return [header, h("p", { className: "body muted empty" }, "الرابط لا يحمل رمز دعوة صحيحاً. اطلب من مالك المشروع رابطاً جديداً."), back];
  }

  let preview;
  try {
    preview = await invitesApi.preview(ctx.code);
  } catch (error) {
    if (error.status === 401) throw error;
    return [header, h("p", { className: "body empty", role: "alert" }, problemText(error)), back];
  }

  const details = h(
    "dl",
    { className: "details invite-details" },
    h("dt", { className: "caption muted" }, "المشروع"),
    h("dd", { className: "headline" }, preview.projectName),
    h("dt", { className: "caption muted" }, "الدور"),
    h("dd", { className: "body" }, `${roleName(preview.role)}: ${roleDescription(preview.role)}`),
    preview.invitedBy ? [h("dt", { className: "caption muted" }, "من"), h("dd", { className: "body" }, preview.invitedBy)] : null,
    h("dt", { className: "caption muted" }, "تنتهي في"),
    h("dd", { className: "body" }, jobDate(preview.expiresAt, { primary: ctx.primary, today: ctx.today, timeZone: ctx.timeZone })),
  );

  const error = h("p", { className: "callout field-error", role: "alert" });
  const join = Button({ variant: "primary" }, "انضمام");
  join.addEventListener("click", async () => {
    error.textContent = "";
    join.disabled = true;
    try {
      const { projectId } = await invitesApi.accept(ctx.code);
      ctx.announce(`انضممت إلى «${preview.projectName}».`);
      await ctx.onJoined(projectId);
    } catch (failure) {
      if (failure.status !== 401) error.textContent = problemText(failure);
      join.disabled = false;
    }
  });

  return [
    header,
    h("section", { className: "zm-card invite-card", "aria-label": "الدعوة" }, details, error, h("div", { className: "sheet-actions" }, join, ButtonLink({ variant: "quiet", href: "#/today" }, "ليس الآن"))),
  ];
}
