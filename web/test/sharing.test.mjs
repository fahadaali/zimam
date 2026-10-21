import assert from "node:assert/strict";
import { test } from "node:test";
import { codeFromJoinLocation, extractInviteCode } from "../public/app/lib/invites.js";
import {
  assigneeOptions,
  canEdit,
  inviteMessage,
  inviteShareLink,
  inviteTitle,
  memberName,
  sharingErrorText,
  showAssignee,
} from "../public/app/lib/sharing.js";

const code = "Zx9_Kq-3vB7mN2pL5tR8wY1aC4dF6gH0jS3uE5iO7k";

test("an invite link points at this site's join page, with the code after #", () => {
  const created = { id: "i1", code, url: `https://zimam.work/join/#${code}`, expiresAt: 0 };
  assert.equal(inviteShareLink("http://localhost:8787", created), `http://localhost:8787/join/#${code}`);
  assert.equal(inviteShareLink("https://zimam.work", created), created.url);
  // The link round-trips through the join page and the paste box.
  const link = new URL(inviteShareLink("https://zimam.work", created));
  assert.equal(codeFromJoinLocation({ pathname: link.pathname, search: link.search, hash: link.hash }), code);
  assert.equal(extractInviteCode(inviteMessage("المكتب", link.href, code)), code);
  // A malformed code falls back to the server's link.
  assert.equal(inviteShareLink("https://zimam.work", { code: "bad", url: "https://x/join/#bad" }), "https://x/join/#bad");
});

test("the invite message carries the link and the code", () => {
  const message = inviteMessage("المكتب", `https://zimam.work/join/#${code}`, code);
  assert.match(message, /«المكتب»/);
  assert.ok(message.includes(`https://zimam.work/join/#${code}`));
  assert.ok(message.trim().endsWith(code));
});

test("roles: owners and editors edit, viewers read", () => {
  assert.equal(canEdit("owner"), true);
  assert.equal(canEdit("editor"), true);
  assert.equal(canEdit("viewer"), false);
  assert.equal(canEdit(null), false);
  assert.equal(inviteTitle("editor"), "دعوة محرر");
  assert.equal(inviteTitle("viewer"), "دعوة مشاهد");
});

test("members read as «أنت», their name, or «عضو بلا اسم»", () => {
  assert.equal(memberName({ userId: "me", name: "فهد" }, "me"), "أنت");
  assert.equal(memberName({ userId: "u2", name: " سارة " }, "me"), "سارة");
  assert.equal(memberName({ userId: "u3", name: null }, "me"), "عضو بلا اسم");
});

test("assignee choices: none, the members, and a former member still assigned", () => {
  const members = [
    { userId: "me", name: "فهد", role: "owner" },
    { userId: "u2", name: "سارة", role: "editor" },
  ];
  assert.deepEqual(assigneeOptions(members, { me: "me", current: null }), [
    { value: "", label: "بلا إسناد" },
    { value: "me", label: "أنت" },
    { value: "u2", label: "سارة" },
  ]);
  assert.deepEqual(assigneeOptions(members, { me: "me", current: "gone" }).at(-1), { value: "gone", label: "عضو سابق" });
  assert.equal(showAssignee(members.slice(0, 1), null), false);
  assert.equal(showAssignee(members.slice(0, 1), "me"), true);
  assert.equal(showAssignee(members, null), true);
});

test("sharing errors have their own sentences", () => {
  assert.match(sharingErrorText("owner_cannot_leave"), /المالك/);
  assert.equal(sharingErrorText("something_else"), null);
});
