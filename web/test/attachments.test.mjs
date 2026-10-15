import assert from "node:assert/strict";
import { test } from "node:test";
import {
  ATTACHMENT_EXTENSIONS,
  MAX_ATTACHMENT_BYTES,
  acceptAttribute,
  attachmentCount,
  attachmentErrorText,
  attachmentMeta,
  checkAttachment,
  kindOf,
} from "../public/app/lib/attachments.js";

const file = (name, size = 1200) => ({ name, size });

test("a chosen file is checked as the server would", () => {
  assert.equal(checkAttachment(file("عقد.pdf")), null);
  assert.equal(checkAttachment(file("صورة.HEIC")), null);
  assert.equal(checkAttachment(file("بلا امتداد")), null);
  assert.equal(checkAttachment(null).code, "no_file");
  assert.equal(checkAttachment(file("page.html")).code, "invalid_file_type");
  assert.equal(checkAttachment(file("logo.svg")).code, "invalid_file_type");
  assert.equal(checkAttachment(file("فارغ.txt", 0)).code, "empty_file");
  assert.equal(checkAttachment(file("كبير.pdf", MAX_ATTACHMENT_BYTES + 1)).code, "file_too_large");
  assert.equal(checkAttachment(file("كبير.pdf", MAX_ATTACHMENT_BYTES)), null);
  assert.match(checkAttachment(file("كبير.pdf", 11), 10).message, /الحد المسموح/);
});

test("the picker offers the server's extensions", () => {
  assert.ok(acceptAttribute().split(",").every((ext) => ATTACHMENT_EXTENSIONS.includes(ext)));
  for (const ext of [".pdf", ".jpg", ".docx", ".xlsx", ".pptx", ".txt"]) assert.ok(ATTACHMENT_EXTENSIONS.includes(ext));
  for (const ext of [".html", ".svg", ".js", ".exe"]) assert.ok(!ATTACHMENT_EXTENSIONS.includes(ext));
});

test("a file's kind in a word, and its size in Arabic digits", () => {
  assert.equal(kindOf("image/jpeg", "a.jpg"), "صورة");
  assert.equal(kindOf("application/pdf", "a.pdf"), "PDF");
  assert.equal(kindOf("text/plain; charset=utf-8", "a.txt"), "نص");
  assert.equal(kindOf("text/csv; charset=utf-8", "a.csv"), "جدول");
  assert.equal(kindOf("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "a.docx"), "مستند");
  assert.equal(kindOf("application/vnd.ms-powerpoint", "a.ppt"), "عرض تقديمي");
  assert.equal(kindOf("", "x"), "ملف");
  assert.equal(attachmentMeta({ contentType: "application/pdf", fileName: "عقد.pdf", size: 5 * 1024 * 1024 }), "PDF، ٥ ميغابايت");
  assert.equal(attachmentMeta({ contentType: "image/png", fileName: "a.png", size: 2048 }), "صورة، ٢ كيلوبايت");
});

test("attachment counts agree with the number", () => {
  assert.equal(attachmentCount(0), "لا مرفقات");
  assert.equal(attachmentCount(1), "مرفق واحد");
  assert.equal(attachmentCount(2), "مرفقان");
  assert.equal(attachmentCount(3), "٣ مرفقات");
  assert.equal(attachmentCount(10), "١٠ مرفقات");
  assert.equal(attachmentCount(11), "١١ مرفقاً");
  assert.equal(attachmentCount(100), "١٠٠ مرفق");
});

test("server errors read in Arabic", () => {
  assert.match(attachmentErrorText({ code: "storage_quota_exceeded" }), /امتلأت مساحة مرفقاتك/);
  assert.match(attachmentErrorText({ code: "file_too_large" }, { maxBytes: 25 * 1024 * 1024 }), /٢٥ ميغابايت/);
  assert.match(attachmentErrorText({ code: "forbidden" }), /صلاحية/);
  assert.match(attachmentErrorText({ code: "something_new" }), /تعذّر/);
});
