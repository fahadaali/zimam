// Sharing on the web, as in the Apple app (ShareProjectView, TaskCommentsSection): the project's
// «مشاركة» dialog (members and roles; the owner's invites: create, copy the /join/#<code> link,
// revoke; changing roles and removing members; leaving), and in a task's details the assignee
// picker and the comments. Everything here needs the server; nothing is kept offline.
// Plain DOM through h() and textContent; nothing here parses HTML.
import { errorText } from "./lib/api.js";
import { Button, h, lightDismiss } from "./lib/components.js";
import { boardApi, sharingApi } from "./lib/feature-api.js";
import { jobDate } from "./lib/imports.js";
import { roleDescription, roleName } from "./lib/invites.js";
import { GRANTABLE_ROLES, assigneeOptions, canEdit, inviteMessage, inviteShareLink, inviteTitle, memberName, sharingErrorText, showAssignee } from "./lib/sharing.js";

const problemText = (error) => sharingErrorText(error?.code) ?? errorText(error);

/** Copies text; falls back to selecting it in its field so the person can copy it themselves. */
async function copy(text, field) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    field?.focus();
    field?.select();
    return false;
  }
}

// ——— The «مشاركة» dialog ———

let shareDialog = null;

function dialogShell() {
  if (shareDialog) return shareDialog;
  const title = h("h2", { className: "title", id: "share-title" }, "مشاركة المشروع");
  const subtitle = h("p", { className: "callout muted share-project" });
  const body = h("div", { className: "share-body" });
  const close = Button({ variant: "quiet" }, "إغلاق");
  const el = h(
    "dialog",
    { className: "sheet share-sheet", id: "share-dialog", closedby: "any", "aria-labelledby": "share-title" },
    h("div", { className: "sheet-form" }, title, subtitle, body, h("div", { className: "sheet-actions" }, close)),
  );
  close.addEventListener("click", () => el.close());
  lightDismiss(el);
  document.body.append(el);
  shareDialog = { el, subtitle, body };
  return shareDialog;
}

/**
 * Opens the dialog for a project. `ctx`: { me, primary, today, announce, refreshProjects,
 * onChanged(), onLeft() }.
 */
export async function openShare(project, ctx) {
  const dialog = dialogShell();
  dialog.subtitle.textContent = project.name;
  dialog.body.replaceChildren(h("p", { className: "callout muted", role: "status" }, "يُحمَّل الأعضاء…"));
  if (!dialog.el.open) dialog.el.showModal();
  await drawShare(project, ctx);
}

async function drawShare(project, ctx) {
  const dialog = dialogShell();
  const me = ctx.me?.id;
  forgetMembers(project.id);
  let members;
  let invites = [];
  try {
    ({ members } = await sharingApi.members(project.id));
  } catch (error) {
    if (error.status === 401) return;
    const message = error.code === "network" ? "المشاركة تحتاج اتصالاً بالإنترنت." : problemText(error);
    dialog.body.replaceChildren(h("p", { className: "callout field-error", role: "alert" }, message));
    return;
  }
  const myRole = members.find((m) => m.userId === me)?.role ?? project.role;
  const owner = myRole === "owner";
  // Invites that could not be read are not «no invites»: the owner is told, as ShareProjectView does.
  let invitesProblem = "";
  if (owner) {
    try {
      ({ invites } = await sharingApi.invites(project.id));
    } catch (failure) {
      if (failure.status === 401) return;
      invites = [];
      invitesProblem = failure.code === "network" ? "المشاركة تحتاج اتصالاً بالإنترنت." : problemText(failure);
    }
  }
  const error = h("p", { className: "callout field-error", role: "alert" }, invitesProblem);
  const redraw = async (focusSelector) => {
    await drawShare(project, ctx);
    if (focusSelector) dialog.body.querySelector(focusSelector)?.focus();
  };
  const run = async (button, action) => {
    error.textContent = "";
    button.disabled = true;
    try {
      await action();
      return true;
    } catch (failure) {
      if (failure.status !== 401) error.textContent = problemText(failure);
      button.disabled = false;
      return false;
    }
  };

  const parts = [membersSection(project, members, { me, owner, run, redraw, ctx })];
  if (owner) parts.push(inviteSection(project, { run, redraw, ctx }), invitesSection(project, invites, { run, redraw, ctx }));
  else parts.push(leaveSection(project, myRole, { me, run, ctx }));
  parts.push(error);
  dialog.body.replaceChildren(...parts);
}

function membersSection(project, members, { me, owner, run, redraw, ctx }) {
  const list = h("ul", { className: "member-list", role: "list" });
  for (const member of members) {
    const name = memberName(member, me);
    const info = h(
      "div",
      { className: "member-info" },
      h("span", { className: "body" }, name),
      h("span", { className: "caption muted" }, `${roleName(member.role)}: ${roleDescription(member.role)}`),
    );
    const row = h("li", { className: "member" }, info);
    if (owner && member.role !== "owner") {
      const selectId = `role-${member.userId}`;
      const select = h(
        "select",
        { className: "input callout member-role", id: selectId },
        GRANTABLE_ROLES.map((role) => h("option", { value: role }, roleName(role))),
      );
      select.value = member.role;
      select.addEventListener("change", async () => {
        const ok = await run(select, () => sharingApi.setRole(project.id, member.userId, select.value));
        if (ok) {
          ctx.announce(`صار دور ${name}: ${roleName(select.value)}.`);
          await redraw(`#${CSS.escape(selectId)}`);
        } else select.value = member.role;
      });
      const remove = Button({ variant: "quiet", className: "danger", "aria-label": `إزالة ${name} من المشروع` }, "إزالة");
      const confirm = h(
        "div",
        { className: "member-confirm", hidden: true },
        h("p", { className: "callout" }, `إزالة ${name}؟ تختفي مهام المشروع من أجهزته، وتُلغى إسناداته فيه.`),
        h("div", { className: "sheet-actions" }),
      );
      const yes = Button({ variant: "secondary", className: "danger" }, "إزالة");
      const no = Button({ variant: "quiet" }, "إلغاء");
      confirm.lastChild.append(yes, no);
      remove.addEventListener("click", () => {
        confirm.hidden = false;
        no.focus();
      });
      no.addEventListener("click", () => {
        confirm.hidden = true;
        remove.focus();
      });
      yes.addEventListener("click", async () => {
        if (await run(yes, () => sharingApi.removeMember(project.id, member.userId))) await redraw(".member-list");
      });
      row.append(h("div", { className: "member-actions" }, h("label", { className: "visually-hidden", for: selectId }, `دور ${name}`), select, remove), confirm);
    }
    list.append(row);
  }
  const lonely = members.length <= 1 && owner;
  return h(
    "section",
    { className: "extra-section", "aria-labelledby": "members-title" },
    h("h3", { className: "headline", id: "members-title" }, "الأعضاء"),
    lonely ? h("p", { className: "callout muted" }, "لم تشارك هذا المشروع بعد. أنشئ دعوة وأرسلها لمن تريد.") : null,
    list,
  );
}

function inviteSection(project, { run, redraw, ctx }) {
  const choices = h(
    "fieldset",
    { className: "choices" },
    h("legend", { className: "caption muted" }, "الدور"),
    GRANTABLE_ROLES.map((role) =>
      h("label", { className: "choice callout" }, h("input", { type: "radio", name: "invite-role", value: role, checked: role === "editor" }), roleName(role)),
    ),
  );
  const create = Button({ variant: "primary" }, "إنشاء دعوة");
  const result = h("div", { className: "invite-result", "aria-live": "polite" });
  create.addEventListener("click", async () => {
    const role = choices.querySelector("input:checked")?.value ?? "editor";
    let created;
    const ok = await run(create, async () => {
      created = await sharingApi.createInvite(project.id, role);
    });
    if (!ok) return;
    create.disabled = false;
    const link = inviteShareLink(location.origin, created);
    const field = h("input", { className: "input callout invite-link", id: "invite-link", type: "text", readonly: true, value: link, dir: "ltr" });
    const copyLink = Button({ variant: "secondary" }, "نسخ الرابط");
    const copyMessage = Button({ variant: "quiet" }, "نسخ الرسالة");
    const status = h("p", { className: "caption muted", role: "status" });
    copyLink.addEventListener("click", async () => {
      status.textContent = (await copy(link, field)) ? "نُسخ الرابط." : "حدّد الرابط وانسخه.";
    });
    copyMessage.addEventListener("click", async () => {
      status.textContent = (await copy(inviteMessage(project.name, link, created.code), field)) ? "نُسخت الرسالة مع الرابط والرمز." : "حدّد الرابط وانسخه.";
    });
    result.replaceChildren(
      h("label", { className: "caption muted", for: "invite-link" }, `رابط ${inviteTitle(role)}`),
      field,
      h("div", { className: "sheet-actions" }, copyLink, copyMessage),
      h("p", { className: "caption muted" }, `تنتهي في ${jobDate(created.expiresAt, { primary: ctx.primary, today: ctx.today })}. لا يظهر الرابط مرة أخرى بعد إغلاق هذه النافذة.`),
      status,
    );
    ctx.announce("أُنشئت الدعوة.");
    // The list of active invites gains this one; the link stays in view above it.
    const list = await sharingApi.invites(project.id).catch(() => null);
    if (list) document.getElementById("active-invites")?.replaceWith(invitesSection(project, list.invites, { run, redraw, ctx }));
    field.focus();
    field.select();
  });
  return h(
    "section",
    { className: "extra-section", "aria-labelledby": "invite-title" },
    h("h3", { className: "headline", id: "invite-title" }, "دعوة"),
    h("p", { className: "callout muted" }, "الدعوة تصلح لشخص واحد، وتنتهي بعد سبعة أيام."),
    choices,
    h("div", { className: "sheet-actions" }, create),
    result,
  );
}

function invitesSection(project, invites, { run, redraw, ctx }) {
  const section = h("section", { className: "extra-section", id: "active-invites", "aria-labelledby": "invites-title" });
  if (invites.length === 0) return section;
  const list = h("ul", { className: "member-list", role: "list" });
  for (const invite of invites) {
    const revoke = Button({ variant: "quiet", className: "danger", "aria-label": `إلغاء ${inviteTitle(invite.role)}` }, "إلغاء الدعوة");
    revoke.addEventListener("click", async () => {
      if (await run(revoke, () => sharingApi.revokeInvite(project.id, invite.id))) {
        ctx.announce("أُلغيت الدعوة.");
        await redraw("#invite-title");
      }
    });
    list.append(
      h(
        "li",
        { className: "member" },
        h(
          "div",
          { className: "member-info" },
          h("span", { className: "body" }, inviteTitle(invite.role)),
          h("span", { className: "caption muted" }, `تنتهي في ${jobDate(invite.expiresAt, { primary: ctx.primary, today: ctx.today })}`),
        ),
        h("div", { className: "member-actions" }, revoke),
      ),
    );
  }
  section.append(h("h3", { className: "headline", id: "invites-title" }, "الدعوات السارية"), list);
  return section;
}

function leaveSection(project, role, { me, run, ctx }) {
  const leave = Button({ variant: "secondary", className: "danger" }, "مغادرة المشروع");
  const confirm = h("div", { className: "member-confirm", hidden: true }, h("p", { className: "callout", id: "leave-text" }, "مغادرة المشروع؟ تختفي مهامه من أجهزتك، ولا تعود إلا بدعوة جديدة."));
  const yes = Button({ variant: "secondary", className: "danger", "aria-describedby": "leave-text" }, "مغادرة");
  const no = Button({ variant: "quiet" }, "إلغاء");
  confirm.append(h("div", { className: "sheet-actions" }, yes, no));
  leave.addEventListener("click", () => {
    confirm.hidden = false;
    no.focus();
  });
  no.addEventListener("click", () => {
    confirm.hidden = true;
    leave.focus();
  });
  yes.addEventListener("click", async () => {
    if (!(await run(yes, () => sharingApi.removeMember(project.id, me)))) return;
    shareDialog?.el.close();
    ctx.announce(`غادرت «${project.name}».`);
    await ctx.refreshProjects();
    ctx.onLeft?.();
  });
  return h(
    "section",
    { className: "extra-section" },
    h("p", { className: "callout" }, `دورك في هذا المشروع: ${roleName(role)}.`),
    h("div", { className: "sheet-actions" }, leave),
    confirm,
  );
}

// ——— In a task's details: assignee and comments ———

const membersCache = new Map();

async function projectMembers(projectId) {
  if (!membersCache.has(projectId)) {
    membersCache.set(
      projectId,
      sharingApi.members(projectId).then(
        (r) => r.members,
        (error) => {
          membersCache.delete(projectId);
          throw error;
        },
      ),
    );
  }
  return membersCache.get(projectId);
}

/** Forgets cached members (after the share dialog changed them). */
export function forgetMembers(projectId) {
  if (projectId) membersCache.delete(projectId);
  else membersCache.clear();
}

/**
 * «المسند إليه» for a project task, once the project has more than one member (or the task is
 * assigned). Viewers see it but cannot change it. `ctx`: { me, role, announce, isCurrent(), onChanged(task) }.
 * `update()` on the section follows an assignee changed elsewhere.
 */
export function assigneeSection(task, ctx) {
  const box = h("div", { className: "extra-section assignee" });
  box.update = () => {
    const select = box.querySelector("select");
    if (select && document.activeElement !== select) select.value = task.assigneeId ?? "";
  };
  if (!task.projectId) return box;
  projectMembers(task.projectId)
    .then((members) => {
      if (!ctx.isCurrent() || !showAssignee(members, task.assigneeId)) return;
      const me = ctx.me?.id;
      const select = h(
        "select",
        { className: "input body", id: "assignee-select", disabled: !canEdit(ctx.role) },
        assigneeOptions(members, { me, current: task.assigneeId }).map((o) => h("option", { value: o.value }, o.label)),
      );
      select.value = task.assigneeId ?? "";
      const error = h("p", { className: "caption field-error", role: "alert" });
      select.addEventListener("change", async () => {
        error.textContent = "";
        const previous = task.assigneeId ?? "";
        select.disabled = true;
        try {
          ctx.markLocalChange?.();
          const send = () => boardApi.patchTask(task.id, { assigneeId: select.value || null });
          Object.assign(task, await (ctx.queueTaskRequest ? ctx.queueTaskRequest(task.id, send) : send()));
          ctx.announce(select.value ? `أُسندت المهمة إلى ${select.selectedOptions[0].textContent}.` : "أُلغي الإسناد.");
          ctx.onChanged?.(task);
        } catch (failure) {
          select.value = previous;
          if (failure.status !== 401) error.textContent = errorText(failure);
        } finally {
          select.disabled = !canEdit(ctx.role);
        }
      });
      box.replaceChildren(h("label", { className: "headline", for: "assignee-select" }, "المسند إليه"), select, error);
    })
    .catch(() => {
      /* without members the picker stays hidden */
    });
  return box;
}

/**
 * The task's comments, oldest first, with «أضف تعليقاً». The author deletes their own.
 * `ctx`: { me, primary, today, announce, isCurrent() }. `reload()` on the section reads them again
 * (another member may have commented), keeping the draft.
 */
export function commentsSection(task, ctx) {
  const list = h("ul", { className: "comment-list", role: "list" });
  const input = h("textarea", { className: "input body comment-input", id: "comment-input", rows: "2", maxlength: "5000" });
  const send = Button({ variant: "secondary", type: "submit" }, "إرسال");
  // ⌘↩ / Ctrl+↩ in the box sends the comment, as in other comment boxes.
  input.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey) || event.isComposing) return;
    event.preventDefault();
    if (!send.disabled) form.requestSubmit();
  });
  const error = h("p", { className: "caption field-error", role: "alert" });
  const form = h(
    "form",
    { className: "comment-form", novalidate: true },
    h("label", { className: "caption muted", for: "comment-input" }, "أضف تعليقاً"),
    input,
    h("div", { className: "sheet-actions" }, send),
    error,
  );
  const section = h(
    "section",
    { className: "extra-section", "aria-labelledby": "comments-title" },
    h("h3", { className: "headline", id: "comments-title" }, "التعليقات"),
    list,
    form,
  );

  const draw = (comments) => {
    if (comments.length === 0) {
      list.replaceChildren(h("li", { className: "callout muted" }, "لا تعليقات بعد."));
      return;
    }
    list.replaceChildren(...comments.map((c) => commentItem(c)));
  };

  const commentItem = (comment) => {
    const mine = comment.authorId === ctx.me?.id;
    const author = mine ? "أنت" : comment.authorName?.trim() || "عضو بلا اسم";
    const li = h(
      "li",
      { className: "comment" },
      h("div", { className: "comment-head" }, h("span", { className: "callout comment-author" }, author), h("span", { className: "caption muted" }, jobDate(comment.createdAt, { primary: ctx.primary, today: ctx.today }))),
      h("p", { className: "body comment-body" }, comment.body),
    );
    if (mine) {
      const remove = Button({ variant: "quiet", className: "danger", "aria-label": "حذف التعليق" }, "حذف التعليق");
      const confirm = h("div", { className: "sheet-actions", hidden: true }, h("p", { className: "callout confirm-text" }, "حذف التعليق؟"));
      const yes = Button({ variant: "secondary", className: "danger" }, "حذف");
      const no = Button({ variant: "quiet" }, "إلغاء");
      confirm.append(yes, no);
      remove.addEventListener("click", () => {
        remove.hidden = true;
        confirm.hidden = false;
        no.focus();
      });
      no.addEventListener("click", () => {
        confirm.hidden = true;
        remove.hidden = false;
        remove.focus();
      });
      yes.addEventListener("click", async () => {
        yes.disabled = true;
        try {
          await sharingApi.deleteComment(comment.id);
          ctx.announce("حُذف التعليق.");
          await load();
          input.focus();
        } catch (failure) {
          yes.disabled = false;
          if (failure.status !== 401) error.textContent = errorText(failure);
        }
      });
      li.append(remove, confirm);
    }
    return li;
  };

  /**
   * `quiet`: a reload after a change elsewhere, which keeps the comments shown when it fails, and
   * leaves the list as it is while it holds the focus (drawn anew, the keyboard would lose its place).
   */
  const load = async ({ quiet = false } = {}) => {
    try {
      const { comments } = await sharingApi.comments(task.id);
      if (ctx.isCurrent() && !(quiet && list.contains(document.activeElement))) draw(comments);
    } catch (failure) {
      if (failure.status === 401 || !ctx.isCurrent() || quiet) return;
      list.replaceChildren(h("li", { className: "callout muted" }, failure.code === "network" ? "التعليقات تحتاج اتصالاً بالإنترنت." : errorText(failure)));
    }
  };

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    error.textContent = "";
    const body = input.value.trim();
    if (!body) {
      error.textContent = "اكتب التعليق أولاً.";
      input.focus();
      return;
    }
    send.disabled = true;
    try {
      await sharingApi.addComment(task.id, body);
      input.value = "";
      ctx.announce("أُضيف التعليق.");
      await load();
    } catch (failure) {
      if (failure.status !== 401) error.textContent = errorText(failure);
    } finally {
      send.disabled = false;
    }
  });

  list.append(h("li", { className: "callout muted" }, "تُحمَّل التعليقات…"));
  load();
  // Not while a deletion is being confirmed (the redraw would close it), nor with the focus in the list.
  section.reload = () => !list.querySelector(".comment .sheet-actions:not([hidden])") && !list.contains(document.activeElement) && load({ quiet: true });
  return section;
}
