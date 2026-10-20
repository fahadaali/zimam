import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { avatarKey, MAX_AVATAR_BYTES } from "../src/routes/me";
import { app, call, signIn } from "./helpers";

const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00]);

async function upload(token: string, body: Uint8Array, contentType = "image/jpeg") {
  const response = await app.fetch(
    new Request("https://api.zimam.test/v1/me/avatar", {
      method: "PUT",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": contentType },
      body,
    }),
    env,
  );
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

async function download(token: string) {
  return app.fetch(
    new Request("https://api.zimam.test/v1/me/avatar", { headers: { Authorization: `Bearer ${token}` } }),
    env,
  );
}

describe("Avatar", () => {
  it("has none at first", async () => {
    const { token } = await signIn();
    expect((await call("GET", "/v1/me", { token })).body).toMatchObject({ avatarVersion: null });
    expect((await download(token)).status).toBe(404);
  });

  it("stores a photo, serves it to its owner, and removes it", async () => {
    const { token, userId } = await signIn();
    const res = await upload(token, JPEG);
    expect(res.status).toBe(200);
    expect(typeof res.body.avatarVersion).toBe("number");
    const served = await download(token);
    expect(served.status).toBe(200);
    expect(served.headers.get("Content-Type")).toBe("image/jpeg");
    expect(new Uint8Array(await served.arrayBuffer())).toEqual(JPEG);

    const other = await signIn();
    expect((await download(other.token)).status).toBe(404);

    expect((await upload(token, PNG, "image/png")).status).toBe(200);
    expect((await download(token)).headers.get("Content-Type")).toBe("image/png");

    const removed = await call("DELETE", "/v1/me/avatar", { token });
    expect(removed.body).toMatchObject({ avatarVersion: null });
    expect(await env.ATTACHMENTS.get(avatarKey(userId))).toBeNull();
  });

  it("refuses what is not a photo, an empty body, and a large file", async () => {
    const { token } = await signIn();
    expect((await upload(token, new TextEncoder().encode("<svg></svg>"), "image/svg+xml")).body.error.code).toBe(
      "invalid_file_type",
    );
    expect((await upload(token, new Uint8Array())).status).toBe(400);
    const large = new Uint8Array(MAX_AVATAR_BYTES + 1);
    large.set(JPEG);
    expect((await upload(token, large)).status).toBe(413);
  });

  it("goes with the account", async () => {
    const { token, userId } = await signIn();
    await upload(token, JPEG);
    expect((await call("DELETE", "/v1/me", { token })).status).toBe(204);
    expect(await env.ATTACHMENTS.get(avatarKey(userId))).toBeNull();
  });
});
