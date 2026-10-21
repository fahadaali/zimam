import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { sha256Hex } from "../src/auth/crypto";
import { SIGNED_OUT } from "../src/realtime/channel";
import { channelRealtime, type Realtime } from "../src/realtime/notify";
import { ZimamService } from "../src/service";
import { addMember, call, fakeAi, pullAll, signIn, testAppleKeys, testGoogleKeys, uuid } from "./helpers";

type User = Awaited<ReturnType<typeof signIn>>;

/** Records nudges instead of sending them; `failing` makes every call throw. */
class FakeRealtime implements Realtime {
  notified: { userId: string; seq: number }[] = [];
  closed: { userId: string; sessionHash?: string }[] = [];
  failing = false;
  async notify(userId: string, seq: number) {
    if (this.failing) throw new Error("realtime is down");
    this.notified.push({ userId, seq });
  }
  async close(userId: string, sessionHash?: string) {
    if (this.failing) throw new Error("realtime is down");
    this.closed.push({ userId, sessionHash });
  }
  to(userId: string) {
    return this.notified.filter((n) => n.userId === userId).map((n) => n.seq);
  }
  reset() {
    this.notified = [];
    this.closed = [];
    this.failing = false;
  }
}

const fake = new FakeRealtime();
const base = { appleKeys: testAppleKeys, googleKeys: testGoogleKeys, ai: () => fakeAi, appleTokens: () => null };
const fakeApp = createApp({ ...base, realtime: () => fake });
const realApp = createApp({ ...base, realtime: (e) => channelRealtime(e.USER_CHANNEL) });
type App = typeof realApp;

/** Calls the app with an execution context and waits for its `waitUntil` work (the nudges). */
async function send(app: App, method: string, path: string, options: { token?: string; body?: unknown; headers?: Record<string, string> } = {}) {
  const headers = new Headers(options.headers);
  if (options.token) headers.set("Authorization", `Bearer ${options.token}`);
  if (options.body !== undefined) headers.set("Content-Type", "application/json");
  const ctx = createExecutionContext();
  const response = await app.fetch(
    new Request(`https://api.zimam.test${path}`, {
      method,
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    }),
    env,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return response;
}

async function json(response: Response) {
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

const ticketFor = async (user: User) => json(await send(realApp, "POST", "/v1/realtime/ticket", { token: user.token }));

interface Socket {
  ws: WebSocket;
  messages: string[];
  closed: { code: number; reason: string } | null;
}

const sockets: Socket[] = [];

/** Opens `/v1/realtime` and collects what arrives. Returns the HTTP status when it is not 101. */
async function connect(query: string, headers: Record<string, string> = {}): Promise<Socket | number> {
  const response = await send(realApp, "GET", `/v1/realtime${query}`, { headers: { Upgrade: "websocket", ...headers } });
  if (response.status !== 101) return response.status;
  const ws = response.webSocket!;
  ws.accept();
  const socket: Socket = { ws, messages: [], closed: null };
  ws.addEventListener("message", (event) => {
    socket.messages.push(event.data as string);
  });
  ws.addEventListener("close", (event) => {
    socket.closed = { code: event.code, reason: event.reason };
  });
  sockets.push(socket);
  return socket;
}

async function socketFor(user: User, how: "ticket" | "header" = "header"): Promise<Socket> {
  const socket =
    how === "ticket"
      ? await connect(`?ticket=${encodeURIComponent((await ticketFor(user)).ticket)}`)
      : await connect("", { Authorization: `Bearer ${user.token}` });
  if (typeof socket === "number") throw new Error(`connect failed: ${socket}`);
  // A ping round trip proves the socket reached its channel before the test writes.
  socket.ws.send("ping");
  await until(() => socket.messages.includes("pong"));
  socket.messages = [];
  return socket;
}

async function until(condition: () => boolean, timeout = 2000) {
  const start = Date.now();
  while (!condition()) {
    if (Date.now() - start > timeout) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 100));

const changed = (socket: Socket) => socket.messages.map((m) => JSON.parse(m) as { type: string; seq: number });

const newestSeq = async () =>
  (await env.DB.prepare(`SELECT MAX(seq) AS seq FROM changes`).first<{ seq: number }>())!.seq;

async function createProject(app: App, owner: User) {
  const response = await send(app, "POST", "/v1/projects", { token: owner.token, body: { name: "مشروع مشترك" } });
  return (await json(response)).id as string;
}

const addTask = (app: App, user: User, projectId: string | null) =>
  send(app, "POST", "/v1/tasks", { token: user.token, body: { title: "مهمة", projectId } });

beforeEach(() => fake.reset());

afterEach(() => {
  for (const { ws } of sockets.splice(0)) {
    try {
      ws.close(1000, "test over");
    } catch {
      /* already closed */
    }
  }
});

describe("Realtime tickets", () => {
  it("are issued only to a signed-in user", async () => {
    const user = await signIn();
    expect((await send(realApp, "POST", "/v1/realtime/ticket")).status).toBe(401);
    const response = await send(realApp, "POST", "/v1/realtime/ticket", { token: user.token });
    expect(response.status).toBe(200);
    const body = await json(response);
    expect(body.ticket).toMatch(/^zt_[A-Za-z0-9_-]{40,}$/);
    expect(body.expiresAt - Date.now()).toBeGreaterThan(55_000);
    expect(body.expiresAt - Date.now()).toBeLessThanOrEqual(60_000);

    // Only the hash is stored, with the session it belongs to.
    const stored = await env.DB.prepare(`SELECT * FROM realtime_tickets WHERE ticket_hash = ?`)
      .bind(await sha256Hex(body.ticket))
      .first<{ user_id: string; session_hash: string }>();
    expect(stored).toMatchObject({ user_id: user.userId, session_hash: await sha256Hex(user.token) });
  });

  it("open the socket once", async () => {
    const user = await signIn();
    const { ticket } = await ticketFor(user);
    const socket = await connect(`?ticket=${encodeURIComponent(ticket)}`);
    expect(typeof socket).toBe("object");
    expect(await connect(`?ticket=${encodeURIComponent(ticket)}`)).toBe(401);
  });

  it("expire", async () => {
    const user = await signIn();
    const { ticket } = await ticketFor(user);
    await env.DB.prepare(`UPDATE realtime_tickets SET expires_at = ? WHERE ticket_hash = ?`)
      .bind(Date.now() - 1, await sha256Hex(ticket))
      .run();
    expect(await connect(`?ticket=${encodeURIComponent(ticket)}`)).toBe(401);
  });

  it("end with their session", async () => {
    const user = await signIn();
    const { ticket } = await ticketFor(user);
    expect((await send(realApp, "POST", "/v1/auth/logout", { token: user.token })).status).toBe(204);
    expect(await connect(`?ticket=${encodeURIComponent(ticket)}`)).toBe(401);
  });
});

describe("Opening the socket", () => {
  it("needs a ticket or a session", async () => {
    const user = await signIn();
    expect(await connect("")).toBe(401);
    expect(await connect("?ticket=zt_made-up")).toBe(401);
    expect(await connect("?ticket=nonsense")).toBe(401);
    expect(await connect("", { Authorization: "Bearer zs_not-a-session" })).toBe(401);
    expect(await connect("", { Authorization: `Bearer ${user.token}` })).toEqual(expect.objectContaining({ messages: [] }));
  });

  it("must be a WebSocket upgrade", async () => {
    const user = await signIn();
    const response = await send(realApp, "GET", "/v1/realtime", { token: user.token });
    expect(response.status).toBe(426);
  });

  it("is refused from a foreign web origin", async () => {
    const user = await signIn();
    const { ticket } = await ticketFor(user);
    expect(await connect(`?ticket=${encodeURIComponent(ticket)}`, { Origin: "https://evil.example" })).toBe(403);
    const allowed = await connect(`?ticket=${encodeURIComponent(ticket)}`, { Origin: "https://zimam.work" });
    expect(typeof allowed).toBe("object");
  });

  it("answers ping with pong", async () => {
    const user = await signIn();
    const socket = await socketFor(user);
    socket.ws.send("ping");
    await until(() => socket.messages.includes("pong"));
  });
});

describe("Nudges after writes", () => {
  it("reach the writer and the project's members, not outsiders", async () => {
    const owner = await signIn();
    const member = await signIn();
    const outsider = await signIn();
    const projectId = await createProject(fakeApp, owner);
    await addMember(projectId, member.userId, "viewer");
    fake.reset();

    expect((await addTask(fakeApp, owner, projectId)).status).toBe(201);
    const seq = await newestSeq();
    expect(fake.to(owner.userId)).toEqual([seq]);
    expect(fake.to(member.userId)).toEqual([seq]);
    expect(fake.to(outsider.userId)).toEqual([]);
    // The seq is what a pull would reach.
    expect((await pullAll(member.token)).cursor).toBe(seq);
  });

  it("for an inbox task reach only its owner", async () => {
    const owner = await signIn();
    const other = await signIn();
    const res = await send(fakeApp, "POST", "/v1/sync", {
      token: owner.token,
      body: { mutations: [{ op: "upsert", entity: "task", data: { id: uuid(), title: "خاصة", updatedAt: 1 } }] },
    });
    expect(res.status).toBe(200);
    expect(fake.notified).toEqual([{ userId: owner.userId, seq: await newestSeq() }]);
    expect(fake.to(other.userId)).toEqual([]);
  });

  it("carry the newest seq of a batch", async () => {
    const owner = await signIn();
    const mutations = [1, 2, 3].map((n) => ({ op: "upsert", entity: "task", data: { id: uuid(), title: `مهمة ${n}`, updatedAt: n } }));
    await send(fakeApp, "POST", "/v1/sync", { token: owner.token, body: { mutations } });
    expect(fake.notified).toEqual([{ userId: owner.userId, seq: await newestSeq() }]);
    expect((await pullAll(owner.token)).cursor).toBe(await newestSeq());
  });

  it("are not sent for reads or for writes that change nothing", async () => {
    const owner = await signIn();
    await send(fakeApp, "GET", "/v1/sync", { token: owner.token });
    await send(fakeApp, "PATCH", "/v1/me", { token: owner.token, body: { name: "فهد" } });
    expect(fake.notified).toEqual([]);
  });

  it("follow membership: a joining member and a removed one hear about it", async () => {
    const owner = await signIn();
    const member = await signIn();
    const projectId = await createProject(fakeApp, owner);
    const invite = await json(await send(fakeApp, "POST", `/v1/projects/${projectId}/invites`, { token: owner.token, body: { role: "editor" } }));
    fake.reset();

    expect((await send(fakeApp, "POST", `/v1/invites/${invite.code}/accept`, { token: member.token })).status).toBe(200);
    expect(fake.to(member.userId)).toEqual([await newestSeq()]);

    fake.reset();
    expect((await send(fakeApp, "DELETE", `/v1/projects/${projectId}/members/${member.userId}`, { token: owner.token })).status).toBe(204);
    const seq = await newestSeq();
    expect(fake.to(member.userId)).toEqual([seq]);
    expect((await pullAll(member.token)).cursor).toBe(seq);
  });

  it("reach the members' devices when an account is deleted", async () => {
    const owner = await signIn();
    const member = await signIn();
    const projectId = await createProject(fakeApp, owner);
    await addMember(projectId, member.userId, "editor");
    fake.reset();

    expect((await send(fakeApp, "DELETE", "/v1/me", { token: owner.token })).status).toBe(204);
    expect(fake.to(member.userId).length).toBe(1);
    expect(fake.closed).toEqual([{ userId: owner.userId, sessionHash: undefined }]);
  });

  it("never fail or undo the write", async () => {
    const owner = await signIn();
    fake.failing = true;
    const res = await addTask(fakeApp, owner, null);
    expect(res.status).toBe(201);
    const task = await json(res);
    expect(await env.DB.prepare(`SELECT id FROM tasks WHERE id = ?`).bind(task.id).first()).not.toBeNull();

    // A channel that cannot even be built is skipped too.
    const broken = createApp({
      ...base,
      realtime: () => {
        throw new Error("no binding");
      },
    });
    expect((await addTask(broken, owner, null)).status).toBe(201);
    expect((await send(broken, "POST", "/v1/auth/logout", { token: owner.token })).status).toBe(204);
  });
});

describe("Sockets", () => {
  it("get the newest seq the user can see, outsiders get nothing", async () => {
    const owner = await signIn();
    const member = await signIn();
    const outsider = await signIn();
    const projectId = await createProject(realApp, owner);
    await addMember(projectId, member.userId, "editor");

    const ownerPhone = await socketFor(owner);
    const ownerWeb = await socketFor(owner, "ticket");
    const memberPhone = await socketFor(member);
    const outsiderPhone = await socketFor(outsider);

    expect((await addTask(realApp, member, projectId)).status).toBe(201);
    const seq = await newestSeq();
    for (const socket of [ownerPhone, ownerWeb, memberPhone]) {
      await until(() => socket.messages.length > 0);
      expect(changed(socket)).toEqual([{ type: "changed", seq }]);
    }
    await settle();
    expect(outsiderPhone.messages).toEqual([]);
    expect((await pullAll(owner.token)).cursor).toBe(seq);
  });

  it("hear about writes from Claude and ChatGPT (ZimamService)", async () => {
    const owner = await signIn();
    const member = await signIn();
    const projectId = await createProject(realApp, owner);
    await addMember(projectId, member.userId, "viewer");
    const memberPhone = await socketFor(member);

    const ctx = createExecutionContext();
    const service = new ZimamService(ctx, env);
    const created = await service.createTask(owner.userId, { title: "من كلود", projectId });
    expect(created.ok).toBe(true);
    await waitOnExecutionContext(ctx);

    await until(() => memberPhone.messages.length > 0);
    expect(changed(memberPhone)).toEqual([{ type: "changed", seq: await newestSeq() }]);
  });

  it("close on sign-out, only for that session", async () => {
    const user = await signIn("apple-two-devices");
    const other = await signIn("apple-two-devices");
    const signingOut = await socketFor(user);
    const staying = await socketFor(other, "ticket");

    expect((await send(realApp, "POST", "/v1/auth/logout", { token: user.token })).status).toBe(204);
    await until(() => signingOut.closed !== null);
    expect(signingOut.closed!.code).toBe(SIGNED_OUT);
    await settle();
    expect(staying.closed).toBeNull();

    // The remaining session still hears its own writes.
    await addTask(realApp, other, null);
    await until(() => staying.messages.length > 0);
  });

  it("all close when the account is deleted", async () => {
    const user = await signIn();
    const phone = await socketFor(user);
    const web = await socketFor(user, "ticket");
    expect((await send(realApp, "DELETE", "/v1/me", { token: user.token })).status).toBe(204);
    await until(() => phone.closed !== null && web.closed !== null);
    expect([phone.closed!.code, web.closed!.code]).toEqual([SIGNED_OUT, SIGNED_OUT]);
  });
});

it("the existing app without realtime still works (helpers' call)", async () => {
  const user = await signIn();
  const res = await call("POST", "/v1/tasks", { token: user.token, body: { title: "مهمة" } });
  expect(res.status).toBe(201);
});
