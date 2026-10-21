// Routes of the web app, read from the URL hash: #/today, #/projects/<id>, #/projects/<id>/sections/<sid>,
// #/search?q=…, and on any of them ?task=<id> for the task open in the inspector (wide screens) or
// on its own page (phones), as MainView.swift keeps `selectedTaskId` beside the sidebar selection.
// Pure functions, no DOM; tested in test/routes.test.mjs.

/** "#/projects/abc?task=t1" → { name: "project", id: "abc", task: "t1" }. */
export function parseRoute(hash = "") {
  const text = hash.replace(/^#\/?/, "");
  const [path, search = ""] = text.split("?");
  const parts = path.split("/").filter(Boolean).map(safeDecode);
  const params = new URLSearchParams(search);
  const task = params.get("task") || null;
  const route = routeOf(parts, params);
  return task ? { ...route, task } : route;
}

function safeDecode(part) {
  try {
    return decodeURIComponent(part);
  } catch {
    return part;
  }
}

function routeOf(parts, params) {
  switch (parts[0]) {
    case "upcoming":
    case "inbox":
    case "import":
    case "calendar":
    case "timeline":
    case "matrix":
      return { name: parts[0] };
    case "projects":
      if (!parts[1]) return { name: "projects" };
      if (parts[2] === "sections" && parts[3]) return { name: "project", id: parts[1], section: parts[3] };
      return { name: "project", id: parts[1] };
    case "search":
      return { name: "search", q: params.get("q") ?? "" };
    case "join":
      return { name: "join", code: parts[1] ?? "" };
    default:
      return { name: "today" };
  }
}

/** The hash for a route, without its task. */
export function routeHash(route) {
  const enc = encodeURIComponent;
  switch (route.name) {
    case "project":
      return route.section ? `#/projects/${enc(route.id)}/sections/${enc(route.section)}` : `#/projects/${enc(route.id)}`;
    case "search":
      return route.q ? `#/search?q=${enc(route.q)}` : "#/search";
    case "join":
      return `#/join/${enc(route.code ?? "")}`;
    default:
      return `#/${route.name}`;
  }
}

/** What identifies the view, so a change of the open task alone does not redraw the list. */
export function routeKey(route) {
  return routeHash(route);
}

/** The same place with `taskId` open, or with no task when it is null. */
export function withTask(hash, taskId) {
  const base = routeHash(parseRoute(hash));
  if (!taskId) return base;
  return `${base}${base.includes("?") ? "&" : "?"}task=${encodeURIComponent(taskId)}`;
}

/** The phone tab a route belongs to (SidebarItem.tab in AppNavigation.swift). */
export function tabFor(route) {
  switch (route.name) {
    case "today":
    case "upcoming":
    case "calendar":
    case "search":
      return route.name;
    case "projects":
    case "project":
    case "inbox":
    case "timeline":
    case "matrix":
      return "projects";
    default:
      return null;
  }
}

/** The sidebar row a route highlights on wide screens: "today", "project:<id>", "section:<id>:<sid>", or null. */
export function sidebarItemFor(route) {
  switch (route.name) {
    case "today":
    case "upcoming":
    case "inbox":
    case "calendar":
    case "timeline":
    case "matrix":
    case "search":
      return route.name;
    case "project":
      return route.section ? `section:${route.id}:${route.section}` : `project:${route.id}`;
    default:
      return null;
  }
}
