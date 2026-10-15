import assert from "node:assert/strict";
import { test } from "node:test";
import {
  UNSECTIONED,
  after,
  boardColumns,
  dropIndex,
  inserting,
  moveSection,
  moving,
  placeTask,
  renumbered,
  shownColumns,
} from "../public/app/lib/order.js";

// The same cases as ManualOrderTests in apple/ZimamKit, so the web and the app order alike.

test("inserts between neighbours without touching them", () => {
  assert.deepEqual(inserting(1, [1, 2, 3]), [1, 1.5, 2, 3]);
  assert.deepEqual(inserting(0, [1, 2]), [0, 1, 2]);
  assert.deepEqual(inserting(2, [1, 2]), [1, 2, 3]);
});

test("an empty list starts at one, and out-of-range indexes are clamped", () => {
  assert.deepEqual(inserting(0, []), [1]);
  assert.deepEqual(inserting(5, []), [1]);
  assert.deepEqual(inserting(9, [1, 2]), [1, 2, 3]);
  assert.deepEqual(inserting(-3, [1, 2]), [0, 1, 2]);
});

test("renumbers when the neighbours leave no room", () => {
  // Tasks never ordered by hand all have order 0.
  assert.deepEqual(inserting(1, [0, 0, 0]), [1, 2, 3, 4]);
  const a = 1;
  const next = a + Number.EPSILON;
  assert.deepEqual(inserting(1, [a, next]), [1, 2, 3]);
  assert.deepEqual(renumbered(3), [1, 2, 3]);
});

test("equal orders away from the neighbours are kept", () => {
  assert.deepEqual(inserting(3, [0, 0, 1, 2]), [0, 0, 1, 1.5, 2]);
});

test("moves within a list", () => {
  assert.deepEqual(moving(0, 2, [1, 2, 3, 4]), [2, 3, 3.5, 4]);
  assert.deepEqual(moving(3, 0, [1, 2, 3, 4]), [0, 1, 2, 3]);
  assert.deepEqual(moving(7, 0, [1, 2]), [1, 2]);
});

test("stays ascending and distinct after many inserts at the same place", () => {
  let orders = [1, 2];
  for (let i = 0; i < 200; i++) {
    orders = inserting(1, orders);
    assert.deepEqual(orders, orders.slice().sort((a, b) => a - b));
    assert.equal(new Set(orders).size, orders.length);
  }
});

test("after is past every order", () => {
  assert.equal(after([]), 1);
  assert.equal(after([3, 1, 2]), 4);
  assert.equal(after([-4]), -3);
});

const task = (id, sortOrder, extra = {}) => ({ id, sortOrder, createdAt: 0, status: "todo", sectionId: null, parentId: null, ...extra });

test("columns: «بلا قسم» first, then sections by order; unknown sections count as none", () => {
  const sections = [
    { id: "s2", name: "قيد العمل", sortOrder: 2, createdAt: 0 },
    { id: "s1", name: "للتنفيذ", sortOrder: 1, createdAt: 0 },
  ];
  const tasks = [
    task("a", 2, { sectionId: "s1" }),
    task("b", 1, { sectionId: "s1" }),
    task("c", 0, { sectionId: "gone" }),
    task("d", 0, { status: "done", sectionId: "s2" }),
    task("e", 0, { parentId: "a", sectionId: "s1" }),
  ];
  const columns = boardColumns(sections, tasks);
  assert.deepEqual(columns.map((c) => c.id), [UNSECTIONED, "s1", "s2"]);
  assert.equal(columns[0].name, "بلا قسم");
  assert.deepEqual(columns[0].tasks.map((t) => t.id), ["c"]);
  assert.deepEqual(columns[1].tasks.map((t) => t.id), ["b", "a"]);
  assert.deepEqual(columns[2].tasks, []);
});

test("an empty «بلا قسم» steps aside once there are sections", () => {
  const withSections = boardColumns([{ id: "s1", name: "أ", sortOrder: 1 }], []);
  assert.deepEqual(shownColumns(withSections).map((c) => c.id), ["s1"]);
  assert.deepEqual(shownColumns(boardColumns([], [])).map((c) => c.id), [UNSECTIONED]);
});

test("placing a task changes only it when there is room", () => {
  const column = [task("a", 1), task("b", 2), task("c", 3)];
  const moving = task("x", 9, { sectionId: "other" });
  assert.deepEqual(placeTask(moving, null, 1, column), [{ id: "x", sortOrder: 1.5, sectionId: null }]);
});

test("moving into another column saves the section even when the order happens to stay", () => {
  const column = [task("a", 1, { sectionId: "s1" })];
  const moving = task("x", 2, { sectionId: null });
  assert.deepEqual(placeTask(moving, "s1", 1, column), [{ id: "x", sortOrder: 2, sectionId: "s1" }]);
});

test("a column never ordered by hand is renumbered once", () => {
  const column = [task("a", 0), task("b", 0), task("c", 0)];
  const changes = placeTask(task("x", 0, { sectionId: "s9" }), null, 1, column);
  assert.deepEqual(changes, [
    { id: "a", sortOrder: 1, sectionId: null },
    { id: "x", sortOrder: 2, sectionId: null },
    { id: "b", sortOrder: 3, sectionId: null },
    { id: "c", sortOrder: 4, sectionId: null },
  ]);
});

test("moving up and down within a column counts the index without the task", () => {
  const column = [task("a", 1), task("b", 2), task("c", 3)];
  // b up: to position 0 among [a, c].
  assert.deepEqual(placeTask(column[1], null, 0, column), [{ id: "b", sortOrder: 0, sectionId: null }]);
  // b down: to position 2 among [a, c].
  assert.deepEqual(placeTask(column[1], null, 2, column), [{ id: "b", sortOrder: 4, sectionId: null }]);
  // Dropped where it already is: nothing to save.
  assert.deepEqual(placeTask(column[1], null, 1, column), []);
});

test("sections move one place at a time", () => {
  const sections = [
    { id: "s1", sortOrder: 1 },
    { id: "s2", sortOrder: 2 },
    { id: "s3", sortOrder: 3 },
  ];
  assert.deepEqual(moveSection(sections, "s3", -1), [{ id: "s3", sortOrder: 1.5 }]);
  assert.deepEqual(moveSection(sections, "s1", 1), [{ id: "s1", sortOrder: 2.5 }]);
  assert.deepEqual(moveSection(sections, "s1", -1), []);
  assert.deepEqual(moveSection(sections, "nope", 1), []);
});

test("the drop index counts the cards above the pointer", () => {
  assert.equal(dropIndex(5, [10, 30, 50]), 0);
  assert.equal(dropIndex(35, [10, 30, 50]), 2);
  assert.equal(dropIndex(99, [10, 30, 50]), 3);
  assert.equal(dropIndex(99, []), 0);
});
