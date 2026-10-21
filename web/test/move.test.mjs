import assert from "node:assert/strict";
import { test } from "node:test";
import { INBOX_NAME, knownSections, movableProjects, moveDestinations } from "../public/app/lib/move.js";

const projects = [
  { id: "b", name: "البيت", kind: "project", role: "owner", sortOrder: 2 },
  { id: "f", name: "مجلد", kind: "folder", role: "owner", sortOrder: 0 },
  { id: "a", name: "العمل", kind: "project", role: "editor", sortOrder: 1 },
  { id: "v", name: "مشاهد", kind: "project", role: "viewer", sortOrder: 3 },
  { id: "x", name: "مؤرشف", kind: "project", role: "owner", sortOrder: 4, archivedAt: 1 },
];

test("only projects the person edits, not folders or archived ones", () => {
  assert.deepEqual(
    movableProjects(projects).map((p) => p.id),
    ["b", "a"],
  );
  // A project without a role is the person's own.
  assert.deepEqual(movableProjects([{ id: "o", name: "خاص" }]).map((p) => p.id), ["o"]);
});

test("the inbox first, then projects in order with their sections indented under them", () => {
  const sections = new Map([
    ["a", [{ id: "s2", name: "لاحقاً", sortOrder: 2 }, { id: "s1", name: "الآن", sortOrder: 1 }]],
  ]);
  const places = moveDestinations({ projectId: null, sectionId: null }, projects, sections);
  assert.deepEqual(
    places.map((p) => [p.kind, p.name]),
    [
      ["inbox", INBOX_NAME],
      ["project", "العمل"],
      ["section", "الآن"],
      ["section", "لاحقاً"],
      ["project", "البيت"],
    ],
  );
  const section = places[2];
  assert.equal(section.projectId, "a");
  assert.equal(section.sectionId, "s1");
  assert.equal(section.label, "الآن في العمل");
  assert.equal(section.spoken, "الآن، في العمل");
});

test("marks the task's current place, and only it", () => {
  const sections = new Map([["a", [{ id: "s1", name: "الآن" }]]]);
  const current = (task) => moveDestinations(task, projects, sections).filter((p) => p.current).map((p) => [p.projectId, p.sectionId]);
  assert.deepEqual(current({}), [[null, null]]);
  assert.deepEqual(current({ projectId: "a", sectionId: null }), [["a", null]]);
  assert.deepEqual(current({ projectId: "a", sectionId: "s1" }), [["a", "s1"]]);
});

test("only the inbox when there are no projects", () => {
  assert.deepEqual(moveDestinations({}, []).map((p) => p.kind), ["inbox"]);
});

test("reads sections already on the project objects, and leaves the rest to be fetched", () => {
  const known = knownSections([{ id: "a", sections: [{ id: "s1" }] }, { id: "b" }]);
  assert.deepEqual([...known.keys()], ["a"]);
  assert.deepEqual(known.get("a"), [{ id: "s1" }]);
});
