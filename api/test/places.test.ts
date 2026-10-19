import { describe, expect, it } from "vitest";
import { call, pullAll, push, signIn, uuid } from "./helpers";

const HOME = { latitude: 24.7136, longitude: 46.6753, radius: 200 };

const place = (id: string, updatedAt: number, extra = {}) => ({
  op: "upsert",
  entity: "place",
  data: { id, name: "البيت", ...HOME, updatedAt, ...extra },
});
const task = (id: string, updatedAt = 1000) => ({ op: "upsert", entity: "task", data: { id, title: "شراء الخبز", updatedAt } });
const reminder = (id: string, taskId: string, location: Record<string, unknown>, extra = {}, updatedAt = 1000) => ({
  op: "upsert",
  entity: "reminder",
  data: { id, taskId, kind: "location", location: { ...HOME, name: "البيت", trigger: "arrive", ...location }, updatedAt, ...extra },
});

async function pullWithPlaces(token: string, cursor = 0) {
  const res = await call("GET", `/v1/sync?cursor=${cursor}&include=place`, { token });
  expect(res.status).toBe(200);
  return res.body as { changes: { entity: string; id: string; op: string; data?: Record<string, any> }[]; cursor: number };
}

describe("Saved places", () => {
  it("syncs places to their owner only, and only to apps that ask", async () => {
    const a = await signIn();
    const b = await signIn();
    const id = uuid().toUpperCase();
    const [result] = await push(a.token, [place(id, 1000)]);
    expect(result!.status).toBe("applied");

    const asked = await pullWithPlaces(a.token);
    expect(asked.changes).toEqual([
      {
        entity: "place",
        id: id.toLowerCase(),
        op: "upsert",
        data: { id: id.toLowerCase(), name: "البيت", ...HOME, createdAt: expect.any(Number), updatedAt: 1000 },
      },
    ]);
    // Apps that predate places never see them, and their cursor moves past.
    const old = await pullAll(a.token);
    expect(old.changes).toEqual([]);
    expect(old.cursor).toBe(asked.cursor);
    // Nobody else does.
    expect((await pullWithPlaces(b.token)).changes).toEqual([]);
    const [foreign] = await push(b.token, [place(id, 2000, { name: "سرقة" })]);
    expect(foreign!.status).toBe("forbidden");
    const [foreignDelete] = await push(b.token, [{ op: "delete", entity: "place", id, updatedAt: 3000 }]);
    expect(foreignDelete!.status).toBe("forbidden");
  });

  it("validates names, coordinates and radius", async () => {
    const { token } = await signIn();
    const results = await push(token, [
      place(uuid(), 1000, { name: "  " }),
      place(uuid(), 1000, { latitude: 91 }),
      place(uuid(), 1000, { radius: 10 }),
    ]);
    expect(results.map((r) => r.status)).toEqual(["invalid", "invalid", "invalid"]);
  });

  it("moves every linked reminder when the place changes, and unlinks them when it goes", async () => {
    const { token } = await signIn();
    const placeId = uuid();
    const taskId = uuid();
    const linked = uuid();
    const other = uuid();
    await push(token, [
      place(placeId, 1000),
      task(taskId),
      reminder(linked, taskId, { placeId: placeId.toUpperCase() }),
      reminder(other, taskId, { name: "المكتب", latitude: 21.5 }),
    ]);
    const before = await pullWithPlaces(token);
    expect(before.changes.find((c) => c.id === linked)!.data!.location.placeId).toBe(placeId);

    await push(token, [place(placeId, 2000, { name: "بيتي", latitude: 24.8, radius: 300 })]);
    const moved = await pullWithPlaces(token, before.cursor);
    expect(moved.changes.map((c) => c.id).sort()).toEqual([linked, placeId].sort());
    const copy = moved.changes.find((c) => c.id === linked)!.data!;
    expect(copy.location).toEqual({ latitude: 24.8, longitude: 46.6753, radius: 300, name: "بيتي", trigger: "arrive", placeId });
    // Apps that predate places get the new copy too.
    expect((await pullAll(token, before.cursor)).changes.map((c) => c.id)).toEqual([linked]);

    await push(token, [{ op: "delete", entity: "place", id: placeId, updatedAt: 3000 }]);
    const gone = await pullWithPlaces(token, moved.cursor);
    expect(gone.changes.find((c) => c.id === placeId)!.op).toBe("delete");
    // The reminder stays where the place was.
    expect(gone.changes.find((c) => c.id === linked)!.data!.location).toMatchObject({ latitude: 24.8, name: "بيتي", placeId: null });
  });

  it("drops a link to someone else's place or a deleted one", async () => {
    const a = await signIn();
    const b = await signIn();
    const theirs = uuid();
    const deleted = uuid();
    const taskId = uuid();
    await push(b.token, [place(theirs, 1000)]);
    await push(a.token, [place(deleted, 1000), { op: "delete", entity: "place", id: deleted, updatedAt: 2000 }, task(taskId)]);
    const r1 = uuid();
    const r2 = uuid();
    const results = await push(a.token, [reminder(r1, taskId, { placeId: theirs }), reminder(r2, taskId, { placeId: deleted })]);
    expect(results.map((r) => r.status)).toEqual(["applied", "applied"]);
    const { changes } = await pullAll(a.token);
    expect((changes.find((c) => c.id === r1)!.data!.location as { placeId: string | null }).placeId).toBeNull();
    expect((changes.find((c) => c.id === r2)!.data!.location as { placeId: string | null }).placeId).toBeNull();
  });

  it("stores a location reminder's time and keeps firedAt for apps that leave it out", async () => {
    const { token } = await signIn();
    const taskId = uuid();
    const id = uuid();
    const at = "2027-01-10T17:00:00+03:00";
    await push(token, [task(taskId), reminder(id, taskId, {}, { at })]);
    let data = (await pullAll(token)).changes.find((c) => c.id === id)!.data!;
    expect(data).toMatchObject({ kind: "location", at, firedAt: null });

    await push(token, [reminder(id, taskId, {}, { at, firedAt: 5000 }, 5000)]);
    // An app that predates firedAt re-saves the reminder without it.
    await push(token, [reminder(id, taskId, {}, { at }, 6000)]);
    data = (await pullAll(token)).changes.find((c) => c.id === id)!.data!;
    expect(data.firedAt).toBe(5000);
    // Clearing it is explicit.
    await push(token, [reminder(id, taskId, {}, { at, firedAt: null }, 7000)]);
    data = (await pullAll(token)).changes.find((c) => c.id === id)!.data!;
    expect(data.firedAt).toBeNull();
  });

  it("deletes places with the account", async () => {
    const { token } = await signIn();
    const id = uuid();
    await push(token, [place(id, 1000)]);
    expect((await call("DELETE", "/v1/me", { token })).status).toBe(204);
  });
});
