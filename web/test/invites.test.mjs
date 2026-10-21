import assert from "node:assert/strict";
import { test } from "node:test";
import {
  appJoinHash,
  appSchemeUrl,
  codeFromJoinLocation,
  extractInviteCode,
  inviteErrorText,
  inviteLink,
  isInviteCode,
  legacyJoinRedirect,
  roleDescription,
  roleName,
  webJoinUrl,
} from "../public/app/lib/invites.js";

const code = "Zx9_Kq-3vB7mN2pL5tR8wY1aC4dF6gH0jS3uE5iO7k";
const site = "https://zimam.work";

test("codes are base64url, 8 to 128 characters", () => {
  assert.equal(isInviteCode(code), true);
  assert.equal(isInviteCode("abc"), false);
  assert.equal(isInviteCode("a".repeat(129)), false);
  assert.equal(isInviteCode("abc/def../../me"), false);
  assert.equal(isInviteCode("<script>alert(1)</script>"), false);
  assert.equal(isInviteCode(null), false);
});

test("extracts the code from every link form", () => {
  // The current link: the code in the fragment.
  assert.equal(extractInviteCode(`${site}/join/#${code}`), code);
  assert.equal(extractInviteCode(`${site}/join#${code}`), code);
  assert.equal(extractInviteCode(`انضم إلى مشروعي: ${site}/join/#${code} شكراً`), code);
  // A query, the old path form, and the app's scheme.
  assert.equal(extractInviteCode(`${site}/join/?code=${code}`), code);
  assert.equal(extractInviteCode(`${site}/join/?code=${code}&ref=share`), code);
  assert.equal(extractInviteCode(`${site}/join/#code=${code}`), code);
  assert.equal(extractInviteCode(`https://zimam.work/join/${code}`), code);
  assert.equal(extractInviteCode(`https://zimam.work/join/${code}/?ref=share`), code);
  assert.equal(extractInviteCode(`zimam://join/${code}`), code);
});

test("extracts a bare code or one at the end of the share message", () => {
  assert.equal(extractInviteCode(code), code);
  assert.equal(extractInviteCode(`  ${code}\n`), code);
  assert.equal(extractInviteCode(`وإن لم يفتح، فاختر «الانضمام بدعوة» في المشاريع والصق هذا الرمز: ${code}`), code);
});

test("rejects links without a valid code", () => {
  assert.equal(extractInviteCode(""), null);
  assert.equal(extractInviteCode("رمز خاطئ"), null);
  assert.equal(extractInviteCode("abc"), null);
  assert.equal(extractInviteCode(`${site}/join/`), null);
  assert.equal(extractInviteCode(`${site}/join/#`), null);
  assert.equal(extractInviteCode(`${site}/join/#<img src=x>`), null);
  assert.equal(extractInviteCode(`${site}/join/?code=short`), null);
  assert.equal(extractInviteCode(undefined), null);
});

test("reads the join page's location: fragment, then query, then path", () => {
  assert.equal(codeFromJoinLocation({ pathname: "/join/", hash: `#${code}` }), code);
  assert.equal(codeFromJoinLocation({ pathname: "/join/", hash: `#code=${code}` }), code);
  assert.equal(codeFromJoinLocation({ pathname: "/join/", search: `?code=${code}` }), code);
  assert.equal(codeFromJoinLocation({ pathname: `/join/${code}` }), code);
  assert.equal(codeFromJoinLocation({ pathname: "/join/", hash: `#${encodeURIComponent(code)}` }), code);
  assert.equal(codeFromJoinLocation({ pathname: "/join/" }), null);
  assert.equal(codeFromJoinLocation({ pathname: "/join/", hash: "#nope" }), null);
  assert.equal(codeFromJoinLocation({ pathname: "/join/", hash: "#%E0%A4%A" }), null);
  assert.equal(codeFromJoinLocation(), null);
});

test("sends the old path form from the 404 page to the join page", () => {
  assert.equal(legacyJoinRedirect(`/join/${code}`), `/join/#${code}`);
  assert.equal(legacyJoinRedirect(`/join/${code}/`), `/join/#${code}`);
  assert.equal(legacyJoinRedirect("/join/"), null);
  assert.equal(legacyJoinRedirect("/join/x"), null);
  assert.equal(legacyJoinRedirect("/other/page"), null);
  assert.equal(legacyJoinRedirect(undefined), null);
});

test("builds the links the join page offers", () => {
  assert.equal(appJoinHash(code), `#/join/${code}`);
  assert.equal(webJoinUrl(code), `/app/#/join/${code}`);
  assert.equal(appSchemeUrl(code), `zimam://join/${code}`);
  assert.equal(inviteLink(site, code), `${site}/join/#${code}`);
  // Every link it builds reads back to the same code.
  for (const link of [appJoinHash(code), webJoinUrl(code), appSchemeUrl(code), inviteLink(site, code)]) {
    assert.equal(extractInviteCode(link), code);
  }
});

test("roles and errors in Arabic", () => {
  assert.equal(roleName("editor"), "محرر");
  assert.equal(roleName("viewer"), "مشاهد");
  assert.equal(roleName("other"), "عضو");
  assert.equal(roleDescription("viewer"), "يقرأ ويعلّق فقط");
  assert.equal(inviteErrorText("invite_expired"), "انتهت صلاحية هذه الدعوة. اطلب دعوة جديدة من مالك المشروع.");
  assert.equal(inviteErrorText("invite_used"), "استُعملت هذه الدعوة من قبل. اطلب دعوة جديدة من مالك المشروع.");
  assert.equal(inviteErrorText("internal"), null);
});
