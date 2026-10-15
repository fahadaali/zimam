import { createExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { decodeProtectedHeader, exportPKCS8, generateKeyPair, jwtVerify, UnsecuredJWT } from "jose";
import { beforeEach, describe, expect, it } from "vitest";
import { AppleTokenClient, AppleTokenError, appleRedirectUris, appleTokensFromEnv } from "../src/auth/apple-tokens";
import { ZimamService } from "../src/service";
import { appleToken, call, fakeApple, pullAll, push, signIn, testAppleKeys, testGoogleKeys, uuid } from "./helpers";

const WEB_REDIRECT = "https://zimam-web.fahad2ao.workers.dev/app";
const MCP_REDIRECT = "https://zimam-mcp.fahad2ao.workers.dev/authorize";

type User = Awaited<ReturnType<typeof signIn>>;

beforeEach(() => fakeApple.reset());

const createProject = async (owner: User, name = "مشروع مشترك") =>
  (await call("POST", "/v1/projects", { token: owner.token, body: { name } })).body.id as string;

const addTask = async (user: User, projectId: string | null, extra = {}) =>
  (await call("POST", "/v1/tasks", { token: user.token, body: { title: "مهمة", projectId, ...extra } })).body.id as string;

const comment = async (user: User, taskId: string, body = "تم") =>
  (await call("POST", `/v1/tasks/${taskId}/comments`, { token: user.token, body: { body } })).body.id as string;

async function addReminder(user: User, taskId: string) {
  const id = uuid();
  const [result] = await push(user.token, [
    { op: "upsert", entity: "reminder", data: { id, taskId, kind: "prayer", prayer: "isha", updatedAt: 1 } },
  ]);
  expect(result!.status).toBe("applied");
  return id;
}

/** Adds a member with a chosen join time, so "earliest-joined" is deterministic. */
async function addMemberAt(projectId: string, userId: string, role: "editor" | "viewer", addedAt: number) {
  await env.DB.prepare(`INSERT INTO project_members (project_id, user_id, role, added_at) VALUES (?, ?, ?, ?)`)
    .bind(projectId, userId, role, addedAt)
    .run();
}

const deleteMe = (user: User) => call("DELETE", "/v1/me", { token: user.token });

const userRow = (id: string) => env.DB.prepare(`SELECT * FROM users WHERE id = ?`).bind(id).first<Record<string, unknown>>();

/** Signs in through the app with an authorization code, as SessionStore does (the web adds its redirect URI). */
async function signInWithCode(sub: string, code: string, audience = "app.zimam.ios", redirectUri?: string) {
  const res = await call("POST", "/v1/auth/apple", {
    body: { identityToken: await appleToken(sub, { audience }), authorizationCode: code, redirectUri },
  });
  expect(res.status).toBe(200);
  return { token: res.body.token as string, userId: res.body.user.id as string };
}

describe("Account deletion", () => {
  it("deletes a solo user's data and ends every session", async () => {
    const sub = `apple-${uuid()}`;
    const user = await signIn(sub, "فهد");
    const otherDevice = await signIn(sub);
    const inboxTask = await addTask(user, null, { notes: "سرّي" });
    const projectId = await createProject(user, "البيت");
    const sectionId = uuid();
    await push(user.token, [{ op: "upsert", entity: "section", data: { id: sectionId, projectId, name: "عمود", updatedAt: 1 } }]);
    const projectTask = await addTask(user, projectId, { sectionId });
    const reminderId = await addReminder(user, projectTask);
    const commentId = await comment(user, projectTask, "ملاحظة");
    const invite = await call("POST", `/v1/projects/${projectId}/invites`, { token: user.token, body: { role: "editor" } });

    expect((await deleteMe(user)).status).toBe(204);

    for (const token of [user.token, otherDevice.token]) {
      expect((await call("GET", "/v1/me", { token })).status).toBe(401);
      expect((await call("GET", "/v1/sync?cursor=0", { token })).status).toBe(401);
    }
    const sessions = await env.DB.prepare(`SELECT COUNT(*) AS n FROM sessions WHERE user_id = ?`).bind(user.userId).first<{ n: number }>();
    expect(sessions!.n).toBe(0);

    const row = await userRow(user.userId);
    expect(row).toMatchObject({ apple_sub: `deleted:${user.userId}`, name: null, email: null, settings: "{}" });

    // Tombstones remain for sync, without their text.
    const tasks = await env.DB.prepare(`SELECT id, title, notes, deleted_at FROM tasks WHERE id IN (?, ?)`)
      .bind(inboxTask, projectTask)
      .all<{ title: string; notes: string | null; deleted_at: number | null }>();
    expect(tasks.results).toHaveLength(2);
    for (const t of tasks.results) expect(t).toMatchObject({ title: "", notes: null, deleted_at: expect.any(Number) });
    const project = await env.DB.prepare(`SELECT name, deleted_at FROM projects WHERE id = ?`).bind(projectId).first();
    expect(project).toMatchObject({ name: "", deleted_at: expect.any(Number) });
    expect(await env.DB.prepare(`SELECT name, deleted_at FROM sections WHERE id = ?`).bind(sectionId).first()).toMatchObject({
      name: "",
      deleted_at: expect.any(Number),
    });
    expect(await env.DB.prepare(`SELECT deleted_at FROM reminders WHERE id = ?`).bind(reminderId).first()).toMatchObject({
      deleted_at: expect.any(Number),
    });
    expect(await env.DB.prepare(`SELECT body, deleted_at FROM comments WHERE id = ?`).bind(commentId).first()).toMatchObject({
      body: "",
      deleted_at: expect.any(Number),
    });
    expect(
      await env.DB.prepare(`SELECT revoked_at FROM invites WHERE id = ?`).bind(invite.body.id).first(),
    ).toMatchObject({ revoked_at: expect.any(Number) });

    // Change rows tell the user's other devices (signed out, but offline copies) and any audience.
    const logged = await env.DB.prepare(
      `SELECT entity, entity_id FROM changes WHERE entity_id IN (?, ?, ?, ?)`,
    )
      .bind(inboxTask, projectTask, projectId, reminderId)
      .all<{ entity: string; entity_id: string }>();
    expect(new Set(logged.results.map((r) => r.entity_id))).toEqual(new Set([inboxTask, projectTask, projectId, reminderId]));

    // The same Apple ID starts over with an empty account.
    const again = await signIn(sub);
    expect(again.userId).not.toBe(user.userId);
    expect((await call("GET", "/v1/tasks", { token: again.token })).body.tasks).toEqual([]);
    expect((await call("GET", "/v1/projects", { token: again.token })).body.projects).toEqual([]);
  });

  it("passes a shared project to the earliest-joined member", async () => {
    const owner = await signIn(undefined, "المالك");
    const first = await signIn(undefined, "الأول");
    const later = await signIn(undefined, "الثاني");
    const projectId = await createProject(owner, "رحلة");
    // The viewer joined first, so they inherit even over a later editor.
    await addMemberAt(projectId, later.userId, "editor", 2_000);
    await addMemberAt(projectId, first.userId, "viewer", 1_000);

    const createdByOwner = await addTask(owner, projectId, { assigneeId: owner.userId });
    const createdByLater = await addTask(later, projectId);
    const ownerComment = await comment(owner, createdByLater, "من المالك");
    const laterComment = await comment(later, createdByLater, "من العضو");
    const ownerReminder = await addReminder(owner, createdByLater);
    const pending = await call("POST", `/v1/projects/${projectId}/invites`, { token: owner.token, body: { role: "viewer" } });
    const cursor = (await pullAll(first.token)).cursor;

    expect((await deleteMe(owner)).status).toBe(204);

    const project = await call("GET", `/v1/projects/${projectId}`, { token: first.token });
    expect(project.status).toBe(200);
    expect(project.body).toMatchObject({ ownerId: first.userId, role: "owner", name: "رحلة" });

    const members = await call("GET", `/v1/projects/${projectId}/members`, { token: later.token });
    expect(members.body.members.map((m: { userId: string; role: string }) => [m.userId, m.role])).toEqual([
      [first.userId, "owner"],
      [later.userId, "editor"],
    ]);

    // Other members' devices hear about the new owner, the unassigned task and the removed comment.
    const view = await pullAll(first.token, cursor);
    const byId = new Map(view.changes.map((c) => [c.id, c]));
    expect(byId.get(projectId)).toMatchObject({ op: "upsert", data: { ownerId: first.userId } });
    expect(byId.get(createdByOwner)).toMatchObject({ op: "upsert", data: { assigneeId: null, title: "مهمة" } });
    expect(byId.get(ownerComment)).toMatchObject({ entity: "comment", op: "delete" });
    expect(byId.has(laterComment)).toBe(false);
    expect(byId.has(ownerReminder)).toBe(false);

    // The work stays, other people's comments too.
    const tasks = await call("GET", `/v1/tasks?projectId=${projectId}`, { token: later.token });
    expect(tasks.body.tasks.map((t: { id: string }) => t.id).sort()).toEqual([createdByOwner, createdByLater].sort());
    const comments = await call("GET", `/v1/tasks/${createdByLater}/comments`, { token: later.token });
    expect(comments.body.comments.map((c: { id: string }) => c.id)).toEqual([laterComment]);

    // The departed owner's link no longer works, and the new owner has the owner's powers.
    const accepted = await call("POST", `/v1/invites/${pending.body.code}/accept`, { token: (await signIn()).token });
    expect(accepted.body.error.code).toBe("invite_revoked");
    expect((await call("GET", `/v1/projects/${projectId}/invites`, { token: first.token })).body.invites).toEqual([]);
    expect((await call("POST", `/v1/projects/${projectId}/invites`, { token: first.token, body: { role: "editor" } })).status).toBe(201);
    expect((await call("DELETE", `/v1/projects/${projectId}`, { token: later.token })).status).toBe(403);
    expect((await call("DELETE", `/v1/projects/${projectId}`, { token: first.token })).status).toBe(204);
  });

  it("removes the user from other people's projects", async () => {
    const owner = await signIn();
    const member = await signIn();
    const projectId = await createProject(owner);
    await addMemberAt(projectId, member.userId, "editor", 1);
    const theirs = await addTask(member, projectId, { assigneeId: member.userId });
    const ownersTask = await addTask(owner, projectId);
    const memberComment = await comment(member, ownersTask);
    const ownerComment = await comment(owner, ownersTask);
    const memberReminder = await addReminder(member, ownersTask);
    const memberInbox = await addTask(member, null);
    const ownerCursor = (await pullAll(owner.token)).cursor;

    expect((await deleteMe(member)).status).toBe(204);

    const view = await pullAll(owner.token, ownerCursor);
    const byId = new Map(view.changes.map((c) => [c.id, c]));
    // Tasks they created stay with the project, unassigned.
    expect(byId.get(theirs)).toMatchObject({ op: "upsert", data: { assigneeId: null, ownerId: member.userId } });
    expect(byId.get(memberComment)).toMatchObject({ op: "delete" });
    expect(byId.has(ownerComment)).toBe(false);
    // Personal records never reach other members.
    expect(byId.has(memberReminder)).toBe(false);
    expect(byId.has(memberInbox)).toBe(false);

    const members = await call("GET", `/v1/projects/${projectId}/members`, { token: owner.token });
    expect(members.body.members.map((m: { userId: string }) => m.userId)).toEqual([owner.userId]);
    expect((await call("GET", `/v1/tasks/${theirs}`, { token: owner.token })).body).toMatchObject({ title: "مهمة", assigneeId: null });

    // The departing user's own audience gets the per-user removal rows, as when a member is removed.
    const addressed = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM changes WHERE user_id = ? AND entity = 'project' AND entity_id = ?`,
    )
      .bind(member.userId, projectId)
      .first<{ n: number }>();
    expect(addressed!.n).toBeGreaterThan(0);
  });

  it("deletes a folder and keeps a shared project inside it, moved to the top level", async () => {
    const owner = await signIn();
    const member = await signIn();
    const folderId = uuid();
    const projectId = uuid();
    await push(owner.token, [
      { op: "upsert", entity: "project", data: { id: folderId, kind: "folder", name: "مجلد", updatedAt: 1 } },
      { op: "upsert", entity: "project", data: { id: projectId, parentId: folderId, name: "داخل", updatedAt: 1 } },
    ]);
    await addMemberAt(projectId, member.userId, "editor", 1);

    expect((await deleteMe(owner)).status).toBe(204);
    const project = await call("GET", `/v1/projects/${projectId}`, { token: member.token });
    expect(project.body).toMatchObject({ ownerId: member.userId, parentId: null, role: "owner" });
  });
});

describe("Sign in with Apple tokens", () => {
  it("keeps the refresh token from the authorization code and revokes it on deletion", async () => {
    const sub = `apple-${uuid()}`;
    fakeApple.codes.set("code-1", { refreshToken: "refresh-1", sub });
    const user = await signInWithCode(sub, "code-1");
    expect(fakeApple.exchanged).toEqual([{ code: "code-1", clientId: "app.zimam.ios" }]);
    expect(await userRow(user.userId)).toMatchObject({ apple_refresh_token: "refresh-1", apple_client_id: "app.zimam.ios" });
    // The code and refresh token never reach the client.
    const me = await call("GET", "/v1/me", { token: user.token });
    expect(JSON.stringify(me.body)).not.toContain("refresh-1");

    expect((await call("DELETE", "/v1/me", { token: user.token })).status).toBe(204);
    expect(fakeApple.revoked).toEqual([{ refreshToken: "refresh-1", clientId: "app.zimam.ios" }]);
    expect(await userRow(user.userId)).toMatchObject({ apple_refresh_token: null, apple_client_id: null });
  });

  it("uses the client the identity token was issued to", async () => {
    const sub = `apple-${uuid()}`;
    fakeApple.codes.set("web-code", { refreshToken: "web-refresh", sub });
    const user = await signInWithCode(sub, "web-code", "app.zimam.ios.web");
    expect(fakeApple.exchanged).toEqual([{ code: "web-code", clientId: "app.zimam.ios.web" }]);
    await call("DELETE", "/v1/me", { token: user.token });
    expect(fakeApple.revoked).toEqual([{ refreshToken: "web-refresh", clientId: "app.zimam.ios.web" }]);
  });

  it("exchanges a web code with the redirect URI the page used, when it is allowed", async () => {
    const sub = `apple-${uuid()}`;
    fakeApple.codes.set("site-code", { refreshToken: "site-refresh", sub });
    const user = await signInWithCode(sub, "site-code", "app.zimam.ios.web", WEB_REDIRECT);
    expect(fakeApple.exchanged).toEqual([{ code: "site-code", clientId: "app.zimam.ios.web", redirectUri: WEB_REDIRECT }]);
    expect(await userRow(user.userId)).toMatchObject({ apple_refresh_token: "site-refresh", apple_client_id: "app.zimam.ios.web" });

    // A redirect URI outside the allowlist never reaches Apple; signing in still works.
    fakeApple.codes.set("odd-code", { refreshToken: "odd-refresh", sub });
    const odd = await signInWithCode(sub, "odd-code", "app.zimam.ios.web", "https://evil.example/app");
    expect(odd.userId).toBe(user.userId);
    expect(fakeApple.exchanged).toHaveLength(1);
    expect(await userRow(user.userId)).toMatchObject({ apple_refresh_token: "site-refresh" });

    const bad = await call("POST", "/v1/auth/apple", {
      body: { identityToken: await appleToken(sub, { audience: "app.zimam.ios.web" }), authorizationCode: "x", redirectUri: "not a url" },
    });
    expect(bad.status).toBe(400);
  });

  it("keeps the MCP consent page's code through ZimamService, with its own redirect URI", async () => {
    const tokens = ZimamService.appleTokens;
    const keys = ZimamService.keys;
    ZimamService.appleTokens = () => fakeApple;
    ZimamService.keys = { apple: testAppleKeys, google: testGoogleKeys };
    try {
      const service = new ZimamService(createExecutionContext(), env);
      const sub = `apple-${uuid()}`;
      fakeApple.codes.set("mcp-code", { refreshToken: "mcp-refresh", sub });
      const idToken = await appleToken(sub, { audience: "app.zimam.ios.web", nonce: "handle-9" });
      const signedIn = await service.signInWithApple(idToken, "handle-9", { authorizationCode: "mcp-code", redirectUri: MCP_REDIRECT });
      expect(signedIn.ok).toBe(true);
      if (!signedIn.ok) return;
      expect(fakeApple.exchanged).toEqual([{ code: "mcp-code", clientId: "app.zimam.ios.web", redirectUri: MCP_REDIRECT }]);
      expect(await userRow(signedIn.value.userId)).toMatchObject({ apple_refresh_token: "mcp-refresh" });

      // Without a code, or with a redirect URI that is not allowed, it signs in and keeps nothing new.
      expect((await service.signInWithApple(idToken, "handle-9")).ok).toBe(true);
      fakeApple.codes.set("stray", { refreshToken: "stray-refresh", sub });
      expect((await service.signInWithApple(idToken, "handle-9", { authorizationCode: "stray", redirectUri: "https://zimam-mcp.fahad2ao.workers.dev/other" })).ok).toBe(true);
      expect(fakeApple.exchanged).toHaveLength(1);
    } finally {
      ZimamService.appleTokens = tokens;
      ZimamService.keys = keys;
    }
  });

  it("still signs in when the code is rejected or belongs to someone else", async () => {
    const sub = `apple-${uuid()}`;
    const rejected = await signInWithCode(sub, "unknown-code");
    expect(await userRow(rejected.userId)).toMatchObject({ apple_refresh_token: null });

    fakeApple.codes.set("someone-else", { refreshToken: "not-yours", sub: "apple-other" });
    const mismatched = await signInWithCode(sub, "someone-else");
    expect(await userRow(mismatched.userId)).toMatchObject({ apple_refresh_token: null });
  });

  it("signs in and deletes without the Apple key, skipping Apple", async () => {
    const sub = `apple-${uuid()}`;
    fakeApple.codes.set("code-2", { refreshToken: "refresh-2", sub });
    const kept = await signInWithCode(sub, "code-2");

    fakeApple.configured = false;
    const other = await signInWithCode(`apple-${uuid()}`, "code-3");
    expect(fakeApple.exchanged.map((e) => e.code)).toEqual(["code-2"]);
    expect(await userRow(other.userId)).toMatchObject({ apple_refresh_token: null });

    expect((await call("DELETE", "/v1/me", { token: kept.token })).status).toBe(204);
    expect(fakeApple.revoked).toEqual([]);
    expect(await userRow(kept.userId)).toMatchObject({ apple_sub: `deleted:${kept.userId}`, apple_refresh_token: null });
  });

  it("deletes the account even when Apple fails to revoke", async () => {
    const sub = `apple-${uuid()}`;
    fakeApple.codes.set("code-4", { refreshToken: "refresh-4", sub });
    const user = await signInWithCode(sub, "code-4");
    fakeApple.failRevoke = true;
    expect((await call("DELETE", "/v1/me", { token: user.token })).status).toBe(204);
    expect((await call("GET", "/v1/me", { token: user.token })).status).toBe(401);
    expect(await userRow(user.userId)).toMatchObject({ apple_sub: `deleted:${user.userId}` });
  });
});

describe("Apple token client", () => {
  async function client(responses: Response[]) {
    const { publicKey, privateKey } = await generateKeyPair("ES256", { extractable: true });
    const pem = await exportPKCS8(privateKey);
    const requests: { url: string; form: URLSearchParams }[] = [];
    const fetcher = (async (url: string, init: RequestInit) => {
      requests.push({ url, form: new URLSearchParams(init.body as string) });
      return responses.shift()!;
    }) as unknown as typeof fetch;
    // Secrets set from a shell may keep the .p8 newlines escaped.
    return { apple: new AppleTokenClient("72V86SZ2XC", "KEY123", pem.replace(/\n/g, "\\n"), fetcher), publicKey, requests };
  }

  it("signs the client secret with ES256 and exchanges the code", async () => {
    const idToken = new UnsecuredJWT({}).setSubject("apple-sub").encode();
    const { apple, publicKey, requests } = await client([Response.json({ refresh_token: "r1", id_token: idToken })]);

    expect(await apple.exchangeCode("the-code", "app.zimam.ios")).toEqual({ refreshToken: "r1", sub: "apple-sub" });
    const [request] = requests;
    expect(request!.url).toBe("https://appleid.apple.com/auth/token");
    expect(Object.fromEntries(request!.form)).toMatchObject({
      client_id: "app.zimam.ios",
      code: "the-code",
      grant_type: "authorization_code",
    });
    // The app's codes have no redirect URI.
    expect(request!.form.has("redirect_uri")).toBe(false);
    const secret = request!.form.get("client_secret")!;
    expect(decodeProtectedHeader(secret)).toMatchObject({ alg: "ES256", kid: "KEY123" });
    const { payload } = await jwtVerify(secret, publicKey, { issuer: "72V86SZ2XC", audience: "https://appleid.apple.com" });
    expect(payload.sub).toBe("app.zimam.ios");
    expect(payload.exp! - payload.iat!).toBeLessThanOrEqual(15_777_000);
  });

  it("revokes a refresh token and reports Apple's errors", async () => {
    const { apple, requests } = await client([
      new Response(null, { status: 200 }),
      Response.json({ error: "invalid_grant" }, { status: 400 }),
    ]);
    await apple.revoke("r1", "app.zimam.ios.web");
    expect(requests[0]!.url).toBe("https://appleid.apple.com/auth/revoke");
    expect(Object.fromEntries(requests[0]!.form)).toMatchObject({
      client_id: "app.zimam.ios.web",
      token: "r1",
      token_type_hint: "refresh_token",
    });
    await expect(apple.exchangeCode("used", "app.zimam.ios")).rejects.toThrow(AppleTokenError);
  });

  it("sends a web code's redirect URI, and allows the configured ones", async () => {
    const { apple, requests } = await client([Response.json({ refresh_token: "r2" })]);
    expect(await apple.exchangeCode("web", "app.zimam.ios.web", WEB_REDIRECT)).toEqual({ refreshToken: "r2", sub: null });
    expect(requests[0]!.form.get("redirect_uri")).toBe(WEB_REDIRECT);
    expect(appleRedirectUris(env)).toEqual([WEB_REDIRECT, MCP_REDIRECT]);
    expect(appleRedirectUris({ APPLE_WEB_REDIRECT_URI: " https://a.test/app ", APPLE_REDIRECT_URIS: "https://b.test/x, ,https://c.test/y" })).toEqual([
      "https://a.test/app",
      "https://b.test/x",
      "https://c.test/y",
    ]);
    expect(appleRedirectUris({})).toEqual([]);
  });

  it("is off until the key secrets are set", () => {
    expect(env.APPLE_TEAM_ID).toBe("72V86SZ2XC");
    expect(appleTokensFromEnv({ ...env, APPLE_KEY_ID: undefined, APPLE_PRIVATE_KEY: undefined })).toBeNull();
    expect(appleTokensFromEnv({ ...env, APPLE_KEY_ID: "K", APPLE_PRIVATE_KEY: "pem" })).toBeInstanceOf(AppleTokenClient);
  });
});

describe("Invite revoking", () => {
  it("lets only the owner list and revoke invites", async () => {
    const owner = await signIn();
    const editor = await signIn();
    const outsider = await signIn();
    const projectId = await createProject(owner);
    await addMemberAt(projectId, editor.userId, "editor", 1);
    const create = (role: string) => call("POST", `/v1/projects/${projectId}/invites`, { token: owner.token, body: { role } });
    const first = (await create("editor")).body;
    const second = (await create("viewer")).body;
    expect(first.id).toMatch(/^[0-9a-f-]{36}$/);

    const list = await call("GET", `/v1/projects/${projectId}/invites`, { token: owner.token });
    expect(list.body.invites.map((i: { id: string }) => i.id)).toEqual([first.id, second.id]);
    const revoke = (user: User, id: string, project = projectId) =>
      call("DELETE", `/v1/projects/${project}/invites/${id}`, { token: user.token });

    expect((await revoke(editor, first.id)).status).toBe(403);
    expect((await revoke(outsider, first.id)).status).toBe(404);
    expect((await revoke(owner, uuid())).status).toBe(404);
    // An invite id only works under its own project.
    const otherProject = await createProject(owner);
    expect((await revoke(owner, first.id, otherProject)).status).toBe(404);

    expect((await revoke(owner, first.id)).status).toBe(204);
    expect((await revoke(owner, first.id)).status).toBe(204);
    const after = await call("GET", `/v1/projects/${projectId}/invites`, { token: owner.token });
    expect(after.body.invites.map((i: { id: string }) => i.id)).toEqual([second.id]);

    const guest = await signIn();
    const preview = await call("GET", `/v1/invites/${first.code}`, { token: guest.token });
    expect(preview).toMatchObject({ status: 410, body: { error: { code: "invite_revoked" } } });
    expect((await call("POST", `/v1/invites/${first.code}/accept`, { token: guest.token })).status).toBe(410);
    expect((await call("GET", `/v1/projects/${projectId}`, { token: guest.token })).status).toBe(404);

    // A used invite cannot be revoked; the member stays.
    expect((await call("POST", `/v1/invites/${second.code}/accept`, { token: guest.token })).status).toBe(200);
    const used = await revoke(owner, second.id);
    expect(used).toMatchObject({ status: 410, body: { error: { code: "invite_used" } } });
    expect((await call("GET", `/v1/projects/${projectId}`, { token: guest.token })).status).toBe(200);
  });
});
