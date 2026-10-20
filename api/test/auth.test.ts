import { generateKeyPair } from "jose";
import { describe, expect, it } from "vitest";
import { appleToken, call, signIn } from "./helpers";

describe("Sign in with Apple", () => {
  it("creates a user and session from a valid identity token", async () => {
    const res = await call("POST", "/v1/auth/apple", {
      body: { identityToken: await appleToken("apple-001", { email: "a@example.com" }), name: "فهد" },
    });
    expect(res.status).toBe(200);
    expect(res.body.token).toMatch(/^zs_/);
    expect(res.body.user).toMatchObject({ name: "فهد", email: "a@example.com", settings: { calendar: "hijri" } });

    const me = await call("GET", "/v1/me", { token: res.body.token });
    expect(me.status).toBe(200);
    expect(me.body.id).toBe(res.body.user.id);
  });

  it("returns the same user on the next sign-in and keeps the first name", async () => {
    const first = await signIn("apple-002", "سارة");
    const second = await call("POST", "/v1/auth/apple", { body: { identityToken: await appleToken("apple-002") } });
    expect(second.body.user.id).toBe(first.userId);
    expect(second.body.user.name).toBe("سارة");
  });

  it("accepts the web Services ID as audience", async () => {
    const res = await call("POST", "/v1/auth/apple", {
      body: { identityToken: await appleToken("apple-web", { audience: "app.zimam.ios.web" }) },
    });
    expect(res.status).toBe(200);
  });

  it.each([
    ["a foreign audience", { audience: "com.other.app" }],
    ["a foreign issuer", { issuer: "https://evil.example" }],
    ["an expired token", { expiresIn: "-1m" }],
  ])("rejects %s", async (_, options) => {
    const res = await call("POST", "/v1/auth/apple", { body: { identityToken: await appleToken("apple-003", options) } });
    expect(res.status).toBe(401);
  });

  it("rejects a token signed by another key", async () => {
    const { privateKey } = await generateKeyPair("RS256");
    const res = await call("POST", "/v1/auth/apple", {
      body: { identityToken: await appleToken("apple-004", { key: privateKey }) },
    });
    expect(res.status).toBe(401);
  });

  it("checks the nonce when the client sends one", async () => {
    const token = await appleToken("apple-005", { nonce: "n-123" });
    expect((await call("POST", "/v1/auth/apple", { body: { identityToken: token, nonce: "n-123" } })).status).toBe(200);
    expect((await call("POST", "/v1/auth/apple", { body: { identityToken: token, nonce: "other" } })).status).toBe(401);
  });

  it("requires a session for protected routes", async () => {
    expect((await call("GET", "/v1/tasks")).status).toBe(401);
    expect((await call("GET", "/v1/tasks", { token: "zs_not-a-session" })).status).toBe(401);
  });

  it("ends the session on logout", async () => {
    const { token } = await signIn();
    expect((await call("POST", "/v1/auth/logout", { token })).status).toBe(204);
    expect((await call("GET", "/v1/me", { token })).status).toBe(401);
  });
});

describe("Account", () => {
  it("updates name and settings", async () => {
    const { token } = await signIn();
    const res = await call("PATCH", "/v1/me", { token, body: { name: "فهد", settings: { calendar: "gregorian" } } });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ name: "فهد", settings: { calendar: "gregorian", prayerMethod: "ummAlQura" } });
    expect((await call("PATCH", "/v1/me", { token, body: { settings: { calendar: "julian" } } })).status).toBe(400);
  });

  it("keeps the Asr madhab and prayer alerts", async () => {
    const { token } = await signIn();
    expect((await call("GET", "/v1/me", { token })).body).toMatchObject({ settings: { asrMadhab: "shafi", prayerAlerts: {} } });
    const alerts = { asr: { adhan: true, iqama: true, iqamaMinutes: 20 } };
    const res = await call("PATCH", "/v1/me", { token, body: { settings: { asrMadhab: "hanafi", prayerAlerts: alerts } } });
    expect(res.body).toMatchObject({ settings: { asrMadhab: "hanafi", prayerAlerts: alerts } });
    const tooLong = { asr: { adhan: true, iqama: true, iqamaMinutes: 90 } };
    expect((await call("PATCH", "/v1/me", { token, body: { settings: { prayerAlerts: tooLong } } })).status).toBe(400);
    expect((await call("PATCH", "/v1/me", { token, body: { settings: { prayerAlerts: { sunrise: tooLong.asr } } } })).status).toBe(400);
  });

  it("deletes the account and its data", async () => {
    const { token } = await signIn("apple-delete");
    await call("POST", "/v1/tasks", { token, body: { title: "مهمة" } });
    expect((await call("DELETE", "/v1/me", { token })).status).toBe(204);
    expect((await call("GET", "/v1/me", { token })).status).toBe(401);

    const again = await signIn("apple-delete");
    const tasks = await call("GET", "/v1/tasks", { token: again.token });
    expect(tasks.body.tasks).toEqual([]);
  });
});
