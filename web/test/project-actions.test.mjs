import assert from "node:assert/strict";
import { test } from "node:test";
import {
  announcement,
  ARCHIVE_NOTE,
  archiveLabel,
  DELETE_NOTE,
  deleteQuestion,
  projectErrorText,
  projectPermissions,
  splitArchived,
} from "../public/app/lib/project-actions.js";

test("owners rename, archive and delete; editors rename and archive; viewers do nothing", () => {
  assert.deepEqual(projectPermissions({ role: "owner" }), { canRename: true, canArchive: true, canDelete: true });
  assert.deepEqual(projectPermissions({ role: "editor" }), { canRename: true, canArchive: true, canDelete: false });
  assert.deepEqual(projectPermissions({ role: "viewer" }), { canRename: false, canArchive: false, canDelete: false });
  // An unknown role is not trusted with anything.
  assert.deepEqual(projectPermissions({}), { canRename: false, canArchive: false, canDelete: false });
});

test("archived projects are listed apart, and folders in neither list", () => {
  const projects = [
    { id: "a", name: "العمل" },
    { id: "b", name: "قديم", archivedAt: 1760000000000 },
    { id: "f", name: "مجلد", kind: "folder" },
  ];
  const { active, archived } = splitArchived(projects);
  assert.deepEqual(active.map((p) => p.id), ["a"]);
  assert.deepEqual(archived.map((p) => p.id), ["b"]);
  assert.deepEqual(splitArchived(), { active: [], archived: [] });
});

test("the words: the question names the project and what goes with it", () => {
  assert.equal(archiveLabel({ archivedAt: null }), "أرشفة المشروع");
  assert.equal(archiveLabel({ archivedAt: 1 }), "استرجاع المشروع");
  assert.equal(deleteQuestion("البيت"), "حذف «البيت»؟");
  assert.match(DELETE_NOTE, /مهامه وأقسامه وتذكيراتها/);
  assert.match(DELETE_NOTE, /لا يمكن استرجاعه/);
  assert.match(ARCHIVE_NOTE, /المشاريع المؤرشفة/);
  assert.equal(announcement.deleted("البيت"), "حُذف المشروع «البيت».");
  assert.equal(announcement.renamed("المنزل"), "صار اسم المشروع «المنزل».");
  // The house rules: no middle dot beside Arabic text, no emoji.
  for (const text of [DELETE_NOTE, ARCHIVE_NOTE, deleteQuestion("س")]) assert.ok(!text.includes("·"));
});

test("a refused delete says the owner alone deletes", () => {
  assert.equal(projectErrorText({ code: "forbidden" }, "delete"), "المالك وحده يحذف المشروع.");
  assert.equal(projectErrorText({ code: "forbidden" }, "rename"), "لا تملك صلاحية تعديل هذا المشروع.");
  assert.equal(typeof projectErrorText({ code: "internal" }, "delete"), "string");
});
