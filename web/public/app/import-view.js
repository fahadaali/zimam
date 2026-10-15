// #/import: move tasks from Todoist, TickTick, Google Tasks, a CSV file, or (through their OAuth
// flows) Google Calendar, Microsoft To Do, Notion, Trello, Asana and TickTick into Zimam.
// The server does the work (POST /v1/imports, then its queue); this view uploads the file or sends
// the token once, or opens the provider's page in this tab (the server's callback returns to
// #/import?pending=<id>&source=<id>, and asks here «استيراد بيانات … إلى حسابك …؟» before
// POST /v1/imports/oauth/confirm starts anything), follows the job until it ends, and lists the
// latest imports.
// Plain DOM through h() and textContent; nothing here parses HTML.
import { request } from "./lib/api.js";
import { Button, h } from "./lib/components.js";
import {
  CONFIRM_NOTE,
  DEFAULT_MAX_BYTES,
  OAUTH_CONFIRM_PATH,
  PENDING_IMPORT_KEY,
  TODOIST_TOKEN_URL,
  acceptList,
  accountLabel,
  checkFile,
  checkToken,
  confirmErrorText,
  confirmQuestion,
  connectLabel,
  countRows,
  extensionsText,
  firstAvailable,
  importErrorText,
  isAvailable,
  isFinished,
  jobDate,
  limitText,
  nextPollDelay,
  oauthErrorText,
  oauthReturn,
  oauthStartPath,
  progressPercent,
  progressText,
  readStoredPending,
  sourceHowTo,
  sourceSubtitle,
  sourceTitle,
  statusText,
  storedPending,
  summaryText,
  usableSources,
} from "./lib/imports.js";
import { arabicNumber } from "./lib/numbers.js";

const importsApi = {
  sources: () => request("GET", "/v1/imports/sources"),
  list: () => request("GET", "/v1/imports"),
  job: (id) => request("GET", `/v1/imports/${encodeURIComponent(id)}`),
  startWithFile: (source, file) => {
    const form = new FormData();
    form.append("source", source);
    form.append("file", file, file.name);
    return request("POST", "/v1/imports", form);
  },
  startWithToken: (source, token) => request("POST", "/v1/imports", { source, token }),
  oauthStart: (source) => request("GET", oauthStartPath(source, location.origin)),
  // Trello's token (from the fragment) is sent once, here, and kept nowhere.
  oauthConfirm: (pending, token) => request("POST", OAUTH_CONFIRM_PATH, token ? { pending, token } : { pending }),
};

/** The route without the provider's return in it: a reload or a shared link does not carry it. */
function clearReturnFromAddress() {
  window.history.replaceState(null, "", `${location.pathname}${location.search}#/import`);
}

/**
 * Before sign-in (main.js): keeps a provider's return (#/import?pending=…) for after it, in this
 * tab only, and clears it from the address bar. Google's sign-in leaves the page, losing the hash.
 * True when there was one.
 */
export function rememberPendingImport() {
  const back = oauthReturn(location.hash);
  if (!back?.pending) return false;
  try {
    sessionStorage.setItem(PENDING_IMPORT_KEY, storedPending(back));
    clearReturnFromAddress();
  } catch {
    /* storage blocked: the hash still carries it through Apple's popup */
  }
  return true;
}

/** After sign-in: whether a kept return waits, so main.js opens #/import. */
export function hasPendingImport() {
  try {
    return readStoredPending(sessionStorage.getItem(PENDING_IMPORT_KEY)) !== null;
  } catch {
    return false;
  }
}

/** The kept return, once. */
function takePendingImport() {
  try {
    const text = sessionStorage.getItem(PENDING_IMPORT_KEY);
    sessionStorage.removeItem(PENDING_IMPORT_KEY);
    return readStoredPending(text);
  } catch {
    return null;
  }
}

/** Each render starts a new generation; a poll from an older one stops. */
let generation = 0;

/**
 * The view. `ctx`: { primary, today, me, announce(text), onImported() } from main.js.
 * Returns its nodes, like the other views.
 */
export async function viewImport(ctx) {
  const gen = ++generation;
  const [sourcesResult, listResult] = await Promise.allSettled([importsApi.sources(), importsApi.list()]);
  if (sourcesResult.status === "rejected") throw sourcesResult.reason;
  const { maxFileBytes = DEFAULT_MAX_BYTES, sources: all = [] } = sourcesResult.value ?? {};
  const sources = usableSources(all);
  let history = listResult.status === "fulfilled" ? listResult.value?.jobs ?? [] : [];

  const header = h(
    "header",
    { className: "view-header" },
    h("h1", { className: "display view-title", tabindex: "-1" }, "استيراد المهام"),
    h("p", { className: "callout muted" }, "انقل مهامك من تطبيق آخر إلى زمام. إعادة استيراد البيانات نفسها تحدّث ما تغيّر ولا تكرر المهام."),
  );

  // ——— Choosing a source ———

  let selected = firstAvailable(sources);
  const choices = h("div", { className: "choices import-sources" });
  for (const source of sources) {
    // An OAuth source whose secrets the server lacks: shown, greyed, and not selectable.
    const available = isAvailable(source);
    const input = h("input", { type: "radio", name: "import-source", value: source.id, checked: source === selected, disabled: !available });
    input.addEventListener("change", () => {
      selected = source;
      showSource();
    });
    choices.append(
      h(
        "label",
        { className: `choice import-choice${available ? "" : " import-choice-unavailable"}` },
        input,
        h(
          "span",
          { className: "import-choice-text" },
          h("span", { className: "callout" }, sourceTitle(source)),
          h("span", { className: "caption muted" }, available ? sourceSubtitle(source.id) : "غير متاح الآن"),
        ),
      ),
    );
  }

  const howTo = h("p", { className: "callout muted import-howto", id: "import-howto" });
  const fileInput = h("input", { className: "input body", id: "import-file", type: "file", "aria-describedby": "import-file-hint import-howto" });
  const fileHint = h("p", { className: "caption muted", id: "import-file-hint" });
  const fileField = h("div", { className: "field" }, h("label", { className: "headline", for: "import-file" }, "الملف"), fileInput, fileHint);

  const tokenInput = h("input", {
    className: "input body",
    id: "import-token",
    type: "password",
    autocomplete: "off",
    spellcheck: "false",
    maxlength: "500",
    "aria-describedby": "import-token-hint import-howto",
  });
  const tokenField = h(
    "div",
    { className: "field" },
    h("label", { className: "headline", for: "import-token" }, "رمز API من Todoist"),
    tokenInput,
    h("p", { className: "caption muted", id: "import-token-hint" }, "يُرسل الرمز إلى خادم زمام مرة واحدة ليقرأ مهامك، ولا يُحفظ في المتصفح ولا في الخادم."),
    h("p", { className: "callout" }, h("a", { className: "import-link", href: TODOIST_TOKEN_URL, target: "_blank", rel: "noopener noreferrer" }, "فتح إعدادات المطوّر في Todoist")),
  );

  const formError = h("p", { className: "callout field-error", id: "import-error", role: "alert" });
  const followRunning = Button({ variant: "secondary", hidden: true }, "متابعة الاستيراد الجاري");
  const submitLabel = () => (selected?.input === "oauth" ? connectLabel(selected) : "بدء الاستيراد");
  const submit = Button({ variant: "primary", type: "submit" }, "بدء الاستيراد");
  const form = h(
    "form",
    { className: "import-form", novalidate: true },
    fileField,
    tokenField,
    formError,
    h("div", { className: "sheet-actions" }, submit, followRunning),
  );

  function showSource() {
    formError.textContent = "";
    followRunning.hidden = true;
    howTo.textContent = selected ? sourceHowTo(selected.id) : "";
    const isFile = selected?.input === "file";
    fileField.hidden = !isFile;
    tokenField.hidden = selected?.input !== "token";
    submit.textContent = submitLabel();
    fileInput.value = "";
    fileInput.setAttribute("accept", acceptList(selected));
    fileHint.textContent = `${limitText(maxFileBytes)} الأنواع: ${extensionsText(selected?.extensions ?? [])}.`;
    tokenInput.value = "";
  }

  fileInput.addEventListener("change", () => {
    formError.textContent = "";
    fileInput.removeAttribute("aria-invalid");
    const file = fileInput.files?.[0];
    const problem = file ? checkFile(file, selected, maxFileBytes) : null;
    if (problem) {
      formError.textContent = problem.message;
      fileInput.setAttribute("aria-invalid", "true");
    }
  });
  tokenInput.addEventListener("input", () => {
    formError.textContent = "";
    tokenInput.removeAttribute("aria-invalid");
  });

  let runningJob = null;
  followRunning.addEventListener("click", () => {
    if (runningJob) follow(runningJob, { focus: true });
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!selected || submit.disabled) return;
    formError.textContent = "";
    followRunning.hidden = true;
    if (selected.input === "oauth") {
      await connect(selected);
      return;
    }
    let start;
    if (selected.input === "file") {
      const file = fileInput.files?.[0];
      const problem = checkFile(file, selected, maxFileBytes);
      if (problem) {
        formError.textContent = problem.message;
        fileInput.setAttribute("aria-invalid", "true");
        fileInput.focus();
        return;
      }
      start = () => importsApi.startWithFile(selected.id, file);
    } else {
      const token = tokenInput.value.trim();
      const problem = checkToken(token);
      if (problem) {
        formError.textContent = problem.message;
        tokenInput.setAttribute("aria-invalid", "true");
        tokenInput.focus();
        return;
      }
      // Sent once and forgotten: the field is cleared before the request goes out.
      tokenInput.value = "";
      start = () => importsApi.startWithToken(selected.id, token);
    }

    submit.disabled = true;
    submit.textContent = selected.input === "file" ? "جارٍ الرفع…" : "جارٍ البدء…";
    try {
      const { job } = await start();
      fileInput.value = "";
      history = [job, ...history.filter((j) => j.id !== job.id)];
      renderHistory();
      follow(job, { focus: true });
    } catch (error) {
      if (error.status === 401) return; // main.js shows sign-in
      formError.textContent = importErrorText(error, { maxFileBytes, extensions: selected.extensions ?? [], input: selected.input });
      if (error.code === "import_in_progress") {
        runningJob = await findRunning();
        followRunning.hidden = !runningJob;
      }
    } finally {
      submit.disabled = false;
      submit.textContent = submitLabel();
    }
  });

  /** Asks the server for the provider's page and goes there in this tab; the callback returns to #/import. */
  async function connect(source) {
    submit.disabled = true;
    submit.textContent = "جارٍ الانتقال…";
    try {
      const { url } = await importsApi.oauthStart(source.id);
      location.assign(url);
    } catch (error) {
      submit.disabled = false;
      submit.textContent = submitLabel();
      if (error.status === 401) return; // main.js shows sign-in
      formError.textContent = importErrorText(error, { input: "oauth" });
      if (error.code === "import_in_progress") {
        runningJob = await findRunning();
        followRunning.hidden = !runningJob;
      }
    }
  }

  async function findRunning() {
    try {
      const { jobs } = await importsApi.list();
      history = jobs;
      renderHistory();
      return jobs.find((j) => !isFinished(j)) ?? null;
    } catch {
      return null;
    }
  }

  const sourceSection = h(
    "section",
    { className: "list-section import-section", "aria-labelledby": "import-source-title" },
    h("h2", { className: "headline section-title", id: "import-source-title" }, "من أين تنقل مهامك؟"),
    sources.length
      ? h("fieldset", { className: "field" }, h("legend", { className: "visually-hidden" }, "المصدر"), choices)
      : h("p", { className: "body muted" }, "لا مصادر متاحة الآن."),
    howTo,
    sources.length ? form : null,
    h("p", { className: "caption muted import-note" }, "تذكيرات أبل تُستورد من تطبيق زمام على الآيفون أو الآيباد أو الماك: «الإعدادات» ثم «استيراد المهام»."),
  );

  // ——— Following a job ———

  const panelTitle = h("h2", { className: "headline section-title", id: "import-job-title", tabindex: "-1" }, "الاستيراد الحالي");
  const panelBody = h("div", { className: "import-job" });
  const panel = h("section", { className: "list-section import-section zm-card", "aria-labelledby": "import-job-title", hidden: true }, panelTitle, panelBody);
  let following = null;

  function renderJob(job) {
    const status = h("p", { className: `headline import-status import-status-${job.status}` }, statusText(job.status));
    const nodes = [
      h("p", { className: "callout" }, sourceTitle({ id: job.source, label: job.source }), job.fileName ? h("span", { className: "muted" }, `، ${job.fileName}`) : null),
      status,
    ];
    if (!isFinished(job)) {
      const percent = progressPercent(job);
      const bar = h("progress", { className: "import-progress", max: "100", "aria-labelledby": "import-progress-text" });
      if (percent != null) bar.value = percent;
      nodes.push(bar, h("p", { className: "callout muted import-progress-text", id: "import-progress-text" }, progressText(job)));
      nodes.push(h("p", { className: "caption muted" }, "يمكنك مغادرة هذه الصفحة؛ يكمل الاستيراد في الخادم، وتظهر المهام بالمزامنة."));
    } else {
      nodes.push(h("p", { className: `body${job.status === "failed" ? " field-error" : ""}` }, summaryText(job)));
    }
    if (job.status !== "queued") {
      const dl = h("dl", { className: "details import-counts" });
      for (const row of countRows(job.counts)) {
        dl.append(h("dt", { className: "caption muted" }, row.label), h("dd", { className: "body" }, arabicNumber(row.value)));
      }
      nodes.push(dl);
      if ((job.counts?.skipped ?? 0) > 0) {
        nodes.push(h("p", { className: "caption muted" }, "«بقي كما عُدِّل في زمام»: عناصر عدّلتها أو حذفتها في زمام بعد آخر استيراد، فلم يُكتب فوقها."));
      }
    }
    if (job.warnings?.length) {
      nodes.push(
        h("h3", { className: "callout import-subtitle" }, "ملاحظات"),
        h("ul", { className: "import-messages", role: "list" }, job.warnings.map((w) => h("li", { className: "callout" }, w))),
      );
    }
    if (job.errors?.length) {
      nodes.push(
        h("h3", { className: "callout import-subtitle" }, "ما تعذّر استيراده"),
        h("ul", { className: "import-messages", role: "list" }, job.errors.map((e) => h("li", { className: "callout field-error" }, e.message))),
      );
    }
    nodes.push(h("p", { className: "caption muted" }, `البدء: ${jobDate(job.createdAt, { primary: ctx.primary, today: ctx.today })}`));
    panelBody.replaceChildren(...nodes);
  }

  /** Shows a job and, while it runs, asks for it again until it ends or the view goes away. */
  async function follow(job, { focus = false } = {}) {
    const token = (following = {});
    panel.hidden = false;
    panelTitle.textContent = isFinished(job) ? "نتيجة الاستيراد" : "الاستيراد الحالي";
    renderJob(job);
    if (focus) panelTitle.focus();
    let failures = 0;
    let current = job;
    while (!isFinished(current)) {
      await new Promise((resolve) => setTimeout(resolve, nextPollDelay(current, failures)));
      if (gen !== generation || following !== token || !panel.isConnected) return;
      try {
        current = (await importsApi.job(current.id)).job;
        failures = 0;
      } catch (error) {
        if (error.status === 401 || error.status === 404) return;
        failures += 1;
        continue;
      }
      if (gen !== generation || following !== token || !panel.isConnected) return;
      renderJob(current);
      history = history.map((j) => (j.id === current.id ? current : j));
      renderHistory();
    }
    if (current !== job) {
      panelTitle.textContent = "نتيجة الاستيراد";
      ctx.announce?.(summaryText(current));
      ctx.onImported?.();
    }
  }

  // ——— History ———

  const historyList = h("ul", { className: "import-history", role: "list" });
  const historySection = h(
    "section",
    { className: "list-section import-section", "aria-labelledby": "import-history-title" },
    h("h2", { className: "headline section-title", id: "import-history-title" }, "آخر عمليات الاستيراد"),
    historyList,
  );

  function renderHistory() {
    historySection.hidden = history.length === 0;
    historyList.replaceChildren(
      ...history.map((job) =>
        h(
          "li",
          { className: "import-history-item" },
          h(
            "button",
            { type: "button", className: "import-history-open", onclick: () => follow(job, { focus: true }) },
            h("span", { className: "body" }, sourceTitle({ id: job.source, label: job.source })),
            h("span", { className: `caption import-status import-status-${job.status}` }, statusText(job.status)),
            job.fileName ? h("span", { className: "caption muted import-history-file" }, job.fileName) : null,
            h("span", { className: "caption muted" }, jobDate(job.createdAt, { primary: ctx.primary, today: ctx.today })),
            h("span", { className: `caption ${job.status === "failed" ? "field-error" : "muted"}` }, summaryText(job)),
          ),
        ),
      ),
    );
  }

  // ——— Back from a provider's page ———

  /**
   * «استيراد بيانات Notion إلى حسابك فهد؟» with «استيراد» and «إلغاء»; true for «استيراد».
   * A provider link someone else started ends here in the account this browser is signed in to,
   * and the server refuses it (404), so the question is what makes the person look.
   */
  function askToConfirm(back) {
    let dialog = document.getElementById("import-confirm");
    if (!dialog) {
      dialog = h("dialog", { className: "sheet", id: "import-confirm", "aria-labelledby": "import-confirm-title", "aria-describedby": "import-confirm-text" });
      document.body.append(dialog);
    }
    const yes = Button({ variant: "primary" }, "استيراد");
    const no = Button({ variant: "quiet" }, "إلغاء");
    dialog.replaceChildren(
      h(
        "div",
        { className: "sheet-form" },
        h("h2", { className: "title", id: "import-confirm-title" }, confirmQuestion(back.source, accountLabel(ctx.me))),
        h("p", { className: "callout", id: "import-confirm-text" }, CONFIRM_NOTE),
        h("div", { className: "sheet-actions" }, yes, no),
      ),
    );
    return new Promise((resolve) => {
      let answer = false;
      yes.addEventListener("click", () => {
        answer = true;
        dialog.close();
      });
      no.addEventListener("click", () => dialog.close());
      dialog.addEventListener("close", () => resolve(answer), { once: true });
      dialog.showModal();
      no.focus();
    });
  }

  async function confirmReturned(back) {
    if (!(await askToConfirm(back))) {
      formError.textContent = "لم يبدأ الاستيراد.";
      return;
    }
    submit.disabled = true;
    try {
      const { job } = await importsApi.oauthConfirm(back.pending, back.token);
      history = [job, ...history.filter((j) => j.id !== job.id)];
      renderHistory();
      follow(job, { focus: true });
    } catch (error) {
      if (error.status === 401) return; // main.js shows sign-in
      formError.textContent = confirmErrorText(error);
      if (error.code === "import_in_progress") {
        runningJob = await findRunning();
        followRunning.hidden = !runningJob;
      }
    } finally {
      submit.disabled = false;
    }
  }

  showSource();
  renderHistory();
  // Back from a provider's page: #/import?pending=<id>&source=<id> (and Trello's &token=…), or
  // ?error=<code>; or the same kept through sign-in. The route drops them at once, so a reload or
  // a copied address does not carry them.
  const inAddress = oauthReturn(location.hash);
  if (inAddress) clearReturnFromAddress();
  const kept = takePendingImport();
  const back = inAddress ?? kept;
  if (back?.error) formError.textContent = oauthErrorText(back.error);
  // After main.js has shown the view: the question is a modal dialog over it.
  if (back?.pending) setTimeout(() => confirmReturned(back), 0);
  // One still running (started here earlier, or in the app) is followed at once.
  const running = history.find((j) => !isFinished(j));
  if (running) queueMicrotask(() => follow(running, { focus: false }));

  return [header, panel, sourceSection, historySection];
}
