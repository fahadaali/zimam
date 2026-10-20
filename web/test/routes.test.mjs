import assert from "node:assert/strict";
import { test } from "node:test";
import { parseRoute, routeHash, routeKey, sidebarItemFor, tabFor, withTask } from "../public/app/lib/routes.js";

test("routes from the hash", () => {
  assert.deepEqual(parseRoute(""), { name: "today" });
  assert.deepEqual(parseRoute("#/upcoming"), { name: "upcoming" });
  assert.deepEqual(parseRoute("#/projects"), { name: "projects" });
  assert.deepEqual(parseRoute("#/projects/p1"), { name: "project", id: "p1" });
  assert.deepEqual(parseRoute("#/projects/p1/sections/s1"), { name: "project", id: "p1", section: "s1" });
  assert.deepEqual(parseRoute("#/search?q=%D8%B9%D9%82%D8%AF"), { name: "search", q: "عقد" });
  assert.deepEqual(parseRoute("#/join/abcDEF12"), { name: "join", code: "abcDEF12" });
  assert.deepEqual(parseRoute("#/nowhere"), { name: "today" });
});

test("the open task rides on any route", () => {
  assert.deepEqual(parseRoute("#/today?task=t1"), { name: "today", task: "t1" });
  assert.deepEqual(parseRoute("#/search?q=x&task=t2"), { name: "search", q: "x", task: "t2" });
  assert.deepEqual(parseRoute("#/projects/p1/sections/s1?task=t3"), { name: "project", id: "p1", section: "s1", task: "t3" });
});

test("withTask adds and removes the task, keeping the place", () => {
  assert.equal(withTask("#/today", "t1"), "#/today?task=t1");
  assert.equal(withTask("#/search?q=x", "t1"), "#/search?q=x&task=t1");
  assert.equal(withTask("#/today?task=t1", "t2"), "#/today?task=t2");
  assert.equal(withTask("#/projects/p1?task=t1", null), "#/projects/p1");
  assert.equal(withTask("", "t1"), "#/today?task=t1");
});

test("routeKey ignores the open task", () => {
  assert.equal(routeKey(parseRoute("#/projects/p1?task=a")), routeKey(parseRoute("#/projects/p1")));
  assert.notEqual(routeKey(parseRoute("#/projects/p1")), routeKey(parseRoute("#/projects/p2")));
  assert.notEqual(routeKey(parseRoute("#/search?q=a")), routeKey(parseRoute("#/search?q=b")));
  for (const hash of ["#/today", "#/projects/p1/sections/s1", "#/search?q=x", "#/join/abcDEF12"]) {
    assert.equal(routeHash(parseRoute(hash)), hash);
  }
});

test("tabs and sidebar rows, as AppNavigation.swift maps them", () => {
  assert.equal(tabFor(parseRoute("#/today")), "today");
  assert.equal(tabFor(parseRoute("#/calendar")), "calendar");
  assert.equal(tabFor(parseRoute("#/search")), "search");
  for (const hash of ["#/projects", "#/projects/p1", "#/inbox", "#/timeline", "#/matrix"]) assert.equal(tabFor(parseRoute(hash)), "projects");
  assert.equal(tabFor(parseRoute("#/import")), null);
  assert.equal(sidebarItemFor(parseRoute("#/inbox")), "inbox");
  assert.equal(sidebarItemFor(parseRoute("#/projects/p1")), "project:p1");
  assert.equal(sidebarItemFor(parseRoute("#/projects/p1/sections/s1")), "section:p1:s1");
  assert.equal(sidebarItemFor(parseRoute("#/projects")), null);
});
