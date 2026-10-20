import { describe, expect, it } from "vitest";
import { call, signIn } from "./helpers";

describe("Prayer times API", () => {
  it("has no days until a location is saved", async () => {
    const { token } = await signIn();
    const res = await call("GET", "/v1/prayers?from=2026-10-20", { token });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ location: null, days: [], method: "ummAlQura", timeZone: "Asia/Riyadh" });
  });

  it("gives each day's prayers and sunrise at the saved location, in order", async () => {
    const { token } = await signIn();
    await call("PATCH", "/v1/me", { token, body: { settings: { location: { latitude: 24.7136, longitude: 46.6753 } } } });
    const res = await call("GET", "/v1/prayers?from=2026-10-20&to=2026-10-21", { token });
    expect(res.status).toBe(200);
    expect(res.body.days.map((d: { date: string }) => d.date)).toEqual(["2026-10-20", "2026-10-21"]);
    const { times } = res.body.days[0];
    const order = ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"];
    expect(Object.keys(times)).toEqual(order);
    const instants = order.map((name) => times[name].at as number);
    expect([...instants].sort((a, b) => a - b)).toEqual(instants);
    // Riyadh in late October: Fajr before five in the morning, Maghrib before six in the evening.
    expect(times.fajr.time).toMatch(/^04:\d\d$/);
    expect(times.maghrib.time).toMatch(/^17:\d\d$/);
  });

  it("refuses a bad or too long range", async () => {
    const { token } = await signIn();
    await call("PATCH", "/v1/me", { token, body: { settings: { location: { latitude: 21.42, longitude: 39.83 } } } });
    expect((await call("GET", "/v1/prayers?from=2026-13-01", { token })).status).toBe(400);
    expect((await call("GET", "/v1/prayers?from=2026-10-21&to=2026-10-20", { token })).status).toBe(400);
    expect((await call("GET", "/v1/prayers?from=2026-10-01&to=2026-12-01", { token })).status).toBe(400);
    expect((await call("GET", "/v1/prayers", {})).status).toBe(401);
  });
});
