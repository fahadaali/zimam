// «المرفقات» in the task details dialog (main.js): the task's files with downloads, adding one,
// and deleting with a confirmation. Files go through the API with the session (GET
// /v1/attachments/:id), then download from a blob: link; nothing is kept in the browser.
import { request, requestBlob } from "./lib/api.js";
import {
  MAX_ATTACHMENT_BYTES,
  acceptAttribute,
  attachmentCount,
  attachmentErrorText,
  attachmentMeta,
  checkAttachment,
} from "./lib/attachments.js";
import { Button, h } from "./lib/components.js";
import { formatSize } from "./lib/imports.js";

const path = (id) => encodeURIComponent(id);

const attachmentsApi = {
  list: (taskId) => request("GET", `/v1/tasks/${path(taskId)}/attachments`),
  upload: (taskId, file) => {
    const form = new FormData();
    form.append("file", file, file.name);
    return request("POST", `/v1/tasks/${path(taskId)}/attachments`, form);
  },
  remove: (id) => request("DELETE", `/v1/attachments/${path(id)}`),
  download: (id) => requestBlob(`/v1/attachments/${path(id)}`),
};

/** Each opened task starts a new generation; answers for an older one are dropped. */
let generation = 0;

/**
 * Fills `container` with the task's attachments. `announce(text)` speaks what happened. → { reload }:
 * reads the list again (another member may have added or removed a file).
 */
export function showAttachments(container, task, { announce = () => {} } = {}) {
  const gen = ++generation;
  const current = () => gen === generation;
  let items = [];
  let maxBytes = MAX_ATTACHMENT_BYTES;

  const title = h("h3", { className: "headline", id: "task-attachments-title" }, "المرفقات");
  const status = h("p", { className: "caption muted", role: "status" }, "جارٍ تحميل المرفقات…");
  const list = h("ul", { className: "attachment-list", "aria-labelledby": "task-attachments-title", hidden: true });
  const error = h("p", { className: "callout field-error", role: "alert" });
  const input = h("input", { type: "file", accept: acceptAttribute(), hidden: true });
  const add = Button({ variant: "secondary", "aria-describedby": "attachment-hint" }, "إضافة مرفق");
  const hint = h("p", { className: "caption muted", id: "attachment-hint" });
  const actions = h("div", { className: "attachment-actions", hidden: true }, add, hint, input);
  container.replaceChildren(title, status, list, error, actions);

  const setHint = () => {
    hint.textContent = `صورة أو PDF أو نص أو مستند Office، حتى ${formatSize(maxBytes)} للملف.`;
  };
  setHint();

  const showError = (e) => {
    if (current() && e?.status !== 401) error.textContent = attachmentErrorText(e, { maxBytes });
  };

  function render() {
    status.textContent = items.length ? attachmentCount(items.length) : "لا مرفقات بعد.";
    list.replaceChildren(...items.map(row));
    list.hidden = items.length === 0;
  }

  function row(attachment) {
    const name = h(
      "button",
      { type: "button", className: "attachment-name body" },
      h("span", { className: "zm-sr" }, "تنزيل: "),
      attachment.fileName,
    );
    name.addEventListener("click", () => download(attachment, name));
    const body = h("div", { className: "attachment-body" }, name, h("span", { className: "caption muted" }, attachmentMeta(attachment)));
    const li = h("li", { className: "attachment" }, body);
    if (attachment.canDelete) li.append(deleteControls(attachment));
    return li;
  }

  /** «حذف», then «حذف نهائياً» or «إبقاء» in its place. */
  function deleteControls(attachment) {
    const box = h("div", { className: "attachment-row-actions" });
    const ask = () => {
      const confirm = Button({ variant: "secondary", className: "danger" }, "حذف نهائياً");
      const keep = Button({ variant: "quiet" }, "إبقاء");
      confirm.addEventListener("click", () => remove(attachment, confirm));
      keep.addEventListener("click", () => {
        idle();
        box.querySelector("button")?.focus();
      });
      box.replaceChildren(h("span", { className: "caption" }, `حذف «${attachment.fileName}»؟`), confirm, keep);
      keep.focus();
    };
    const idle = () => {
      const start = Button({ variant: "quiet", "aria-label": `حذف ${attachment.fileName}` }, "حذف");
      start.addEventListener("click", ask);
      box.replaceChildren(start);
    };
    idle();
    return box;
  }

  async function download(attachment, button) {
    error.textContent = "";
    button.disabled = true;
    try {
      const blob = await attachmentsApi.download(attachment.id);
      if (!current()) return;
      const url = URL.createObjectURL(blob);
      // Inside the dialog: everything outside a modal dialog is inert.
      const link = h("a", { href: url, download: attachment.fileName, hidden: true });
      container.append(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
    } catch (e) {
      showError(e);
    } finally {
      button.disabled = false;
    }
  }

  async function remove(attachment, button) {
    error.textContent = "";
    button.disabled = true;
    try {
      await attachmentsApi.remove(attachment.id);
      if (!current()) return;
      items = items.filter((a) => a.id !== attachment.id);
      render();
      announce("حُذف المرفق.");
      (add.hidden ? title : add).focus?.();
    } catch (e) {
      button.disabled = false;
      showError(e);
    }
  }

  add.addEventListener("click", () => input.click());
  input.addEventListener("change", async () => {
    const file = input.files?.[0];
    input.value = "";
    if (!file) return;
    error.textContent = "";
    const problem = checkAttachment(file, maxBytes);
    if (problem) {
      error.textContent = problem.message;
      return;
    }
    add.disabled = true;
    add.textContent = "جارٍ الرفع…";
    try {
      const created = await attachmentsApi.upload(task.id, file);
      if (!current()) return;
      items = [...items, created];
      render();
      announce(`أُرفق «${created.fileName}».`);
    } catch (e) {
      showError(e);
    } finally {
      if (current()) {
        add.disabled = false;
        add.textContent = "إضافة مرفق";
      }
    }
  });

  /** `quiet`: a reload after a change elsewhere, which keeps what is shown when it fails. */
  const load = ({ quiet = false } = {}) =>
    attachmentsApi
      .list(task.id)
      .then((answer) => {
        if (!current()) return;
        items = answer.attachments ?? [];
        maxBytes = answer.maxFileBytes ?? maxBytes;
        setHint();
        actions.hidden = !answer.canAdd;
        render();
      })
      .catch((e) => {
        if (!current() || quiet) return;
        status.textContent = "";
        showError(e);
      });

  load();
  return {
    // Not while a file is uploading or a deletion is being confirmed: the redraw would cut it short.
    reload: () => current() && !add.disabled && !list.querySelector(".attachment-row-actions .danger") && load({ quiet: true }),
  };
}
