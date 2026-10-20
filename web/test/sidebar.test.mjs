import assert from "node:assert/strict";
import { test } from "node:test";
import { sidebarCounts, sidebarProjects } from "../public/app/lib/sidebar.js";

const task = (fields) => ({ status: "todo", parentId: null, projectId: null, sectionId: null, dueDate: null, ...fields });

test("counts open top-level tasks for today, the inbox, projects and sections", () => {
  const counts = sidebarCounts(
    [
      task({ dueDate: "2026-10-19" }), // overdue counts for today
      task({ dueDate: "2026-10-20", projectId: "p1", sectionId: "s1" }),
      task({ dueDate: "2026-10-21", projectId: "p1" }),
      task({ projectId: "p2" }),
      task({ parentId: "x", dueDate: "2026-10-20" }), // a subtask: never counted
      task({ status: "done", dueDate: "2026-10-20" }),
    ],
    "2026-10-20",
  );
  assert.equal(counts.today, 2);
  assert.equal(counts.inbox, 1);
  assert.equal(counts.byProject.get("p1"), 2);
  assert.equal(counts.byProject.get("p2"), 1);
  assert.equal(counts.bySection.get("s1"), 1);
});

test("projects in their order, without folders or archived ones, with sorted sections", () => {
  const projects = [
    { id: "b", kind: "project", sortOrder: 2 },
    { id: "f", kind: "folder", sortOrder: 0 },
    { id: "a", kind: "project", sortOrder: 1 },
    { id: "z", kind: "project", sortOrder: 0, archivedAt: 5 },
  ];
  const sections = new Map([["a", [{ id: "s2", sortOrder: 2 }, { id: "s1", sortOrder: 1 }]]]);
  const items = sidebarProjects(projects, sections);
  assert.deepEqual(items.map((i) => i.project.id), ["a", "b"]);
  assert.deepEqual(items[0].sections.map((s) => s.id), ["s1", "s2"]);
  assert.deepEqual(items[1].sections, []);
});
