import assert from "node:assert/strict";
import { test } from "node:test";
import { fetchAllPages, TASK_PAGE_LIMIT, TASK_PAGE_SIZE } from "../public/app/lib/api.js";

/** A fake GET /v1/tasks over `total` tasks that records the offsets it was asked for. */
function pages(total, pageSize = TASK_PAGE_SIZE) {
  const offsets = [];
  const fetchPage = async (offset) => {
    offsets.push(offset);
    const count = Math.max(0, Math.min(pageSize, total - offset));
    return { tasks: Array.from({ length: count }, (_, i) => ({ id: `t${offset + i}` })) };
  };
  return { offsets, fetchPage };
}

test("one short page is the whole list", async () => {
  const { offsets, fetchPage } = pages(3);
  const { tasks, truncated } = await fetchAllPages(fetchPage);
  assert.deepEqual(offsets, [0]);
  assert.deepEqual(tasks.map((t) => t.id), ["t0", "t1", "t2"]);
  assert.equal(truncated, false);
});

test("an empty list asks once", async () => {
  const { offsets, fetchPage } = pages(0);
  assert.deepEqual(await fetchAllPages(fetchPage), { tasks: [], truncated: false });
  assert.deepEqual(offsets, [0]);
});

test("full pages read on by offset and join in order", async () => {
  const { offsets, fetchPage } = pages(1203);
  const { tasks } = await fetchAllPages(fetchPage);
  assert.deepEqual(offsets, [0, 500, 1000]);
  assert.equal(tasks.length, 1203);
  assert.equal(tasks[0].id, "t0");
  assert.equal(tasks[1202].id, "t1202");
});

test("a list that ends on a full page asks once more and stops at the empty one", async () => {
  const { offsets, fetchPage } = pages(1000);
  const { tasks, truncated } = await fetchAllPages(fetchPage);
  assert.deepEqual(offsets, [0, 500, 1000]);
  assert.equal(tasks.length, 1000);
  assert.equal(truncated, false);
});

test("stops after the page limit, and says the list may go on", async () => {
  const { offsets, fetchPage } = pages(Infinity);
  const { tasks, truncated } = await fetchAllPages(fetchPage);
  assert.equal(offsets.length, TASK_PAGE_LIMIT);
  assert.equal(tasks.length, TASK_PAGE_LIMIT * TASK_PAGE_SIZE);
  assert.equal(truncated, true);
});

test("page size and limit can be set", async () => {
  const { offsets, fetchPage } = pages(10, 2);
  const { tasks } = await fetchAllPages(fetchPage, { pageSize: 2, maxPages: 3 });
  assert.deepEqual(offsets, [0, 2, 4]);
  assert.equal(tasks.length, 6);
});

test("a failed page fails the whole read", async () => {
  await assert.rejects(
    fetchAllPages(async (offset) => {
      if (offset > 0) throw new Error("network");
      return { tasks: Array.from({ length: TASK_PAGE_SIZE }, (_, i) => ({ id: i })) };
    }),
    /network/,
  );
});
