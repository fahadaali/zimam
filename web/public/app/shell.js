// The app's frame (index.html, shell.css), as MainView.swift and SidebarView.swift build it:
// which layout the width calls for, the current tab or sidebar row, the sidebar's projects and
// counts, dropping a task on «صندوق المهام» or a project, the tab bar that shrinks on scroll, the
// account menu, and the «مشروع جديد» and «الانضمام بدعوة» dialogs.
import { avatarView } from "./avatar.js";
import { api, errorText } from "./lib/api.js";
import { IconButton, h } from "./lib/components.js";
import { boardApi } from "./lib/feature-api.js";
import { hydrateIcons, icon } from "./lib/icons.js";
import { appJoinHash, extractInviteCode } from "./lib/invites.js";
import { arabicNumber } from "./lib/numbers.js";
import { sidebarItemFor, tabFor } from "./lib/routes.js";
import { canEdit } from "./lib/sharing.js";
import { sidebarCounts, sidebarProjects } from "./lib/sidebar.js";
import { taskCount } from "./lib/tasks.js";

/** The width from which the sidebar replaces the tab bar; the same literal is in shell.css. */
const REGULAR = "(min-width: 48rem)";
const EXPANDED_KEY = "zimam.sidebarExpanded";
/** At most this many project requests at once when reading sections for the sidebar. */
const SECTION_FETCHES = 4;

const $ = (id) => document.getElementById(id);

/**
 * `ctx` (from main.js): { state, announce, showError, refreshProjects(), render(), onLayout(layout),
 * moveTask(taskId, { projectId, sectionId, label }), sync() }.
 */
export function createShell(ctx) {
  const shell = $("shell");
  const sections = new Map(); // project id → its sections
  let counts = sidebarCounts([], ctx.state.today);
  let selectedItem = null;

  hydrateIcons(document);

  // ——— Layout ———

  const regular = matchMedia(REGULAR);
  const layout = () => (regular.matches ? "regular" : "compact");
  shell.dataset.layout = layout();
  regular.addEventListener("change", () => {
    // The window scrolls on phones and the list column on wide screens: keep the place.
    const main = $("main");
    const from = shell.dataset.layout === "regular" ? main.scrollTop : window.scrollY;
    shell.dataset.layout = layout();
    if (layout() === "regular") main.scrollTop = from;
    else window.scrollTo(0, from);
    ctx.onLayout(layout());
  });

  // ——— Current place ———

  function updateNav(route) {
    for (const link of document.querySelectorAll("[data-tab]")) {
      if (link.dataset.tab === tabFor(route)) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    }
    selectedItem = sidebarItemFor(route);
    if (route.name === "project" && route.section) expand(route.id, true, { render: false });
    markSidebar();
    shell.dataset.route = route.name;
  }

  function markSidebar() {
    for (const link of document.querySelectorAll(".sidebar [data-item]")) {
      if (link.dataset.item === selectedItem) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    }
  }

  // ——— Sidebar projects ———

  function expandedSet() {
    try {
      return new Set(JSON.parse(sessionStorage.getItem(EXPANDED_KEY) ?? "[]"));
    } catch {
      return new Set();
    }
  }

  function expand(projectId, open, { render = true } = {}) {
    const set = expandedSet();
    if (open === set.has(projectId)) return;
    if (open) set.add(projectId);
    else set.delete(projectId);
    try {
      sessionStorage.setItem(EXPANDED_KEY, JSON.stringify([...set]));
    } catch {
      /* kept until the next draw */
    }
    if (render) renderProjects();
  }

  function countBadge(n) {
    if (!n) return null;
    return [h("span", { className: "sidebar-count caption", "aria-hidden": "true" }, arabicNumber(n)), h("span", { className: "zm-sr" }, `، ${taskCount(n)}`)];
  }

  function row({ href, item, iconName, label, count, drop }) {
    const link = h(
      "a",
      { className: "sidebar-row body", href, dataset: { item, ...(drop ? { drop: JSON.stringify(drop) } : {}) } },
      icon(iconName),
      h("span", { className: "sidebar-label" }, label),
      countBadge(count),
    );
    return link;
  }

  function renderProjects() {
    const list = $("sidebar-projects");
    const items = sidebarProjects(ctx.state.projects, sections);
    if (items.length === 0) {
      list.replaceChildren(h("li", { className: "sidebar-empty callout muted" }, "لا مشاريع بعد."));
      return;
    }
    const open = expandedSet();
    list.replaceChildren(
      ...items.map(({ project, sections: projectSections }) => {
        const editable = canEdit(project.role ?? "owner");
        const link = row({
          href: `#/projects/${encodeURIComponent(project.id)}`,
          item: `project:${project.id}`,
          iconName: "folder",
          label: project.name,
          count: counts.byProject.get(project.id),
          drop: editable ? { projectId: project.id, sectionId: null, label: project.name } : null,
        });
        const head = h("div", { className: "sidebar-project" }, link);
        const li = h("li", null, head);
        if (projectSections.length) {
          const expanded = open.has(project.id);
          const toggle = IconButton({
            icon: "chevron-forward",
            label: expanded ? `إخفاء أقسام ${project.name}` : `إظهار أقسام ${project.name}`,
            className: "disclosure",
            "aria-expanded": String(expanded),
          });
          toggle.addEventListener("click", () => expand(project.id, !expanded));
          head.append(toggle);
          if (expanded) {
            li.append(
              h(
                "ul",
                { className: "sidebar-sections", role: "list" },
                projectSections.map((section) =>
                  h(
                    "li",
                    null,
                    row({
                      href: `#/projects/${encodeURIComponent(project.id)}/sections/${encodeURIComponent(section.id)}`,
                      item: `section:${project.id}:${section.id}`,
                      iconName: "section",
                      label: section.name,
                      count: counts.bySection.get(section.id),
                      drop: editable ? { projectId: project.id, sectionId: section.id, label: section.name } : null,
                    }),
                  ),
                ),
              ),
            );
          }
        }
        return li;
      }),
    );
    markSidebar();
  }

  function renderCounts() {
    for (const badge of document.querySelectorAll(".sidebar-list [data-count]")) {
      const n = counts[badge.dataset.count] ?? 0;
      badge.replaceChildren(...(countBadge(n) ?? []));
    }
  }

  /** Reads the open tasks and the projects' sections again, then redraws the sidebar. */
  async function refreshSidebar() {
    try {
      const { tasks } = await api.tasks({ status: "open" });
      counts = sidebarCounts(tasks, ctx.state.today);
    } catch {
      /* the counts wait for the next refresh */
    }
    renderCounts();
    renderProjects();
    await fetchSections();
    renderProjects();
  }

  /**
   * The project list carries each project's sections; a server older than that field leaves it out,
   * so only those projects are read one by one, a few at a time.
   */
  async function fetchSections() {
    const queue = [];
    for (const project of ctx.state.projects) {
      if (project.kind === "folder" || project.archivedAt) continue;
      if (Array.isArray(project.sections)) sections.set(project.id, project.sections);
      else queue.push(project.id);
    }
    if (queue.length === 0) return;
    const worker = async () => {
      while (queue.length) {
        const id = queue.shift();
        try {
          const detail = await boardApi.project(id);
          sections.set(id, detail.sections ?? []);
        } catch {
          /* this project's sections wait for the next refresh */
        }
      }
    };
    await Promise.all(Array.from({ length: SECTION_FETCHES }, worker));
  }

  // ——— Dropping a task on the sidebar ———

  const TASK_TYPE = "application/x-zimam-task";
  const sidebar = $("sidebar");
  const target = (event) => event.target.closest?.("[data-drop]");
  sidebar.addEventListener("dragover", (event) => {
    const el = target(event);
    if (!el || !event.dataTransfer?.types.includes(TASK_TYPE)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    for (const other of sidebar.querySelectorAll(".is-target")) if (other !== el) other.classList.remove("is-target");
    el.classList.add("is-target");
  });
  sidebar.addEventListener("dragleave", (event) => {
    const el = target(event);
    if (el && !el.contains(event.relatedTarget)) el.classList.remove("is-target");
  });
  sidebar.addEventListener("drop", (event) => {
    const el = target(event);
    if (!el) return;
    event.preventDefault();
    el.classList.remove("is-target");
    const taskId = event.dataTransfer.getData(TASK_TYPE);
    if (!taskId) return;
    const where = el.dataset.drop === "inbox" ? { projectId: null, sectionId: null, label: "صندوق المهام" } : JSON.parse(el.dataset.drop);
    ctx.moveTask(taskId, where);
  });
  document.addEventListener("dragend", () => {
    for (const el of sidebar.querySelectorAll(".is-target")) el.classList.remove("is-target");
  });

  // ——— Tab bar: shrinks while scrolling down, as tabBarMinimizeBehavior(.onScrollDown) ———

  const tabbar = $("tabbar");
  let lastY = window.scrollY;
  let ticking = false;
  window.addEventListener(
    "scroll",
    () => {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(() => {
        ticking = false;
        const y = window.scrollY;
        if (shell.dataset.layout !== "compact") return;
        if (y > lastY + 4 && y > tabbar.offsetHeight) tabbar.classList.add("is-minimized");
        else if (y < lastY - 4 || y <= 0) tabbar.classList.remove("is-minimized");
        lastY = y;
      });
    },
    { passive: true },
  );
  tabbar.addEventListener("focusin", () => tabbar.classList.remove("is-minimized"));

  // ——— Account menu ———

  const menu = $("account-menu");
  let menuButton = null;
  menu.addEventListener("beforetoggle", (event) => {
    if (event.newState !== "open" || !menuButton) return;
    const rect = menuButton.getBoundingClientRect();
    const rtl = document.documentElement.dir === "rtl";
    // The menu hangs under the button, its inline end lined up with the button's.
    menu.style.setProperty("--menu-top", `${rect.bottom + 4}px`);
    menu.style.setProperty("--menu-end", `${rtl ? rect.left : window.innerWidth - rect.right}px`);
  });
  menu.addEventListener("click", (event) => {
    if (event.target.closest("a, button")) menu.hidePopover();
  });
  $("sync-button").addEventListener("click", () => ctx.sync());

  /** The photo button that opens the account menu, for a screen's toolbar. */
  function accountButton() {
    const me = ctx.state.me;
    $("account-name").textContent = me?.name || me?.email || "";
    const button = h(
      "button",
      { type: "button", className: "account-button", "aria-label": "الحساب والمزامنة", title: "الحساب والمزامنة", popovertarget: "account-menu" },
      avatarView(me, "callout"),
    );
    button.popoverTargetElement = menu;
    button.addEventListener("pointerdown", () => (menuButton = button));
    button.addEventListener("keydown", () => (menuButton = button));
    button.addEventListener("click", () => (menuButton = button));
    return button;
  }

  // ——— «مشروع جديد» and «الانضمام بدعوة» ———

  const projectDialog = $("project-dialog");
  const projectName = $("project-name");
  const projectError = $("project-error");

  function openNewProject() {
    $("project-form").reset();
    projectError.textContent = "";
    projectDialog.showModal();
    projectName.focus();
  }

  $("project-cancel").addEventListener("click", () => projectDialog.close());
  $("project-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const name = projectName.value.trim();
    if (!name) {
      projectError.textContent = "اكتب اسم المشروع.";
      projectName.focus();
      return;
    }
    const submit = $("project-submit");
    submit.disabled = true;
    try {
      const project = await api.createProject(name);
      projectDialog.close();
      ctx.announce(`أُضيف المشروع «${project.name}».`);
      await ctx.refreshProjects();
      refreshSidebar();
      location.hash = `#/projects/${encodeURIComponent(project.id)}`;
    } catch (error) {
      if (error.status !== 401) projectError.textContent = errorText(error);
    } finally {
      submit.disabled = false;
    }
  });

  const joinDialog = $("join-dialog");
  const joinCode = $("join-code");
  const joinError = $("join-error");

  function openJoin() {
    $("join-form").reset();
    joinError.textContent = "";
    joinDialog.showModal();
    joinCode.focus();
  }

  $("join-cancel").addEventListener("click", () => joinDialog.close());
  $("join-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const code = extractInviteCode(joinCode.value);
    if (!code) {
      joinError.textContent = "لم نجد رمز دعوة في هذا النص. الصق الرابط أو الرمز كما وصلك.";
      joinCode.focus();
      return;
    }
    joinDialog.close();
    location.hash = appJoinHash(code);
  });

  $("new-project-button").addEventListener("click", openNewProject);
  $("join-button").addEventListener("click", openJoin);

  return { layout, updateNav, refreshSidebar, renderCounts, accountButton, openNewProject, openJoin };
}
