import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { DEFAULT_RATE_LIMITS, deleteEndedRateWindows, planRateLimits, releaseRequest, takeRequest } from "../src/ai/limits";
import { AiError, ANTHROPIC_MODEL, AnthropicProvider, DeepSeekProvider, MAX_OUTPUT_TOKENS, providerFromEnv } from "../src/ai/provider";
import { DEFAULT_MONTHLY_LIMIT, monthOf, planMonthlyLimit, resetDate } from "../src/ai/quota";
import { MAX_PROMPT_PROJECTS } from "../src/routes/assistant";
import { addDays, dayIn, dayOfHijri, hijriParts } from "../src/data/dates";
import type { Env } from "../src/env";
import worker from "../src/index";
import { call, deleteAccount, fakeAi, push, signIn, uuid } from "./helpers";

const GATEWAY = "https://gateway.ai.cloudflare.com/v1/302d00b357e2c90ed474d13642708b30/zimam";

/** A full, valid answer to the parse schema; tests override fields. */
function suggestion(fields: Record<string, unknown> = {}) {
  return {
    title: "مراجعة العقد",
    notes: null,
    dueDate: null,
    dueHijri: null,
    dueTime: null,
    duePrayer: null,
    duePrayerOffset: null,
    priority: "none",
    tags: [],
    projectId: null,
    place: null,
    ...fields,
  };
}

async function usage(userId: string) {
  return env.DB.prepare(`SELECT requests, input_tokens, output_tokens FROM ai_usage WHERE user_id = ? AND month = ?`)
    .bind(userId, monthOf(new Date()))
    .first<{ requests: number; input_tokens: number; output_tokens: number }>();
}

async function failures(userId: string) {
  const row = await env.DB.prepare(`SELECT failed_requests FROM ai_usage WHERE user_id = ? AND month = ?`)
    .bind(userId, monthOf(new Date()))
    .first<{ failed_requests: number }>();
  return row?.failed_requests ?? 0;
}

async function createProject(token: string, name: string): Promise<string> {
  const res = await call("POST", "/v1/projects", { token, body: { name } });
  return res.body.id as string;
}

async function createTask(token: string, body: Record<string, unknown>): Promise<string> {
  const res = await call("POST", "/v1/tasks", { token, body });
  if (res.status !== 201) throw new Error(JSON.stringify(res.body));
  return res.body.id as string;
}

beforeEach(() => fakeAi.reset());

describe("POST /v1/assistant/parse", () => {
  const NOW = "2026-10-13T06:00:00+03:00"; // Tuesday 2 Jumada al-Ula 1448 in Riyadh

  it("names at most MAX_PROMPT_PROJECTS projects to the model, first by the user's order", async () => {
    const a = await signIn();
    const total = MAX_PROMPT_PROJECTS + 25;
    const ids = Array.from({ length: total }, () => uuid());
    const now = Date.now();
    await env.DB.batch(
      ids.flatMap((id, i) => [
        env.DB.prepare(
          `INSERT INTO projects (id, owner_id, kind, name, view, sort_order, created_at, updated_at) VALUES (?, ?, 'project', ?, 'list', ?, ?, ?)`,
        ).bind(id, a.userId, `مشروع ${i}`, i, now, now),
        env.DB.prepare(`INSERT INTO project_members (project_id, user_id, role, added_at) VALUES (?, ?, 'owner', ?)`).bind(id, a.userId, now),
      ]),
    );
    fakeAi.answer(suggestion({ title: "مهمة", projectId: ids.at(-1) }));
    const res = await call("POST", "/v1/assistant/parse", { token: a.token, body: { text: "مهمة", now: NOW } });
    expect(res.status).toBe(200);
    // A project the model was not told of is not taken from its answer.
    expect(res.body.projectId).toBeUndefined();
    const prompt = fakeAi.requests[0]!.prompt;
    expect(prompt).toContain(`${ids[0]} | مشروع 0`);
    expect(prompt).toContain(ids[MAX_PROMPT_PROJECTS - 1]);
    expect(prompt).not.toContain(ids[MAX_PROMPT_PROJECTS]);
  });

  it("turns a note into a validated suggestion without saving it", async () => {
    const a = await signIn();
    const b = await signIn();
    const work = await createProject(a.token, "العمل");
    const foreign = await createProject(b.token, "خاص");

    fakeAi.answer(
      suggestion({
        title: "مراجعة العقد 📄.",
        dueDate: "2026-10-15",
        dueTime: "18:00",
        duePrayer: "maghrib",
        duePrayerOffset: 0,
        priority: "medium",
        tags: ["#عمل", "عمل", "🔥"],
        projectId: foreign,
      }),
      { input: 900, output: 60 },
    );
    const res = await call("POST", "/v1/assistant/parse", {
      token: a.token,
      body: { text: "ذكرني أراجع العقد بعد المغرب يوم الخميس #عمل", now: NOW },
    });
    expect(res.status).toBe(200);
    // The foreign project is dropped, the time yields to the prayer, emoji and the # go.
    expect(res.body).toEqual({
      title: "مراجعة العقد",
      dueDate: "2026-10-15",
      duePrayer: "maghrib",
      duePrayerOffset: 0,
      priority: "medium",
      tags: ["عمل"],
    });

    const [request] = fakeAi.requests;
    expect(request!.prompt).toContain("TODAY: 2026-10-13, Tuesday (الثلاثاء), Hijri 1448-5-2");
    expect(request!.prompt).toContain("2026-10-15 | Thursday | الخميس");
    expect(request!.prompt).toContain(`${work} | العمل`);
    expect(request!.prompt).not.toContain(foreign);
    expect(request!.prompt).toContain("<note>\nذكرني أراجع العقد بعد المغرب يوم الخميس #عمل\n</note>");
    expect(request!.schema).toMatchObject({ type: "object", additionalProperties: false });

    expect(await usage(a.userId)).toEqual({ requests: 1, input_tokens: 900, output_tokens: 60 });
    const tasks = await call("GET", "/v1/tasks", { token: a.token });
    expect(tasks.body.tasks).toEqual([]);
  });

  it("keeps the user's own project and gives a time-only note today's date", async () => {
    const { token } = await signIn();
    const home = await createProject(token, "البيت");
    fakeAi.answer(suggestion({ title: "شراء الخبز", dueTime: "21:30", projectId: home.toUpperCase(), priority: "high" }));
    const res = await call("POST", "/v1/assistant/parse", { token, body: { text: "اشتر الخبز الساعة ٩:٣٠ مشروع البيت", now: NOW } });
    expect(res.body).toEqual({ title: "شراء الخبز", dueDate: "2026-10-13", dueTime: "21:30", priority: "high", tags: [], projectId: home });
  });

  it("ties the reminder to one of the user's saved places, or names an unsaved one", async () => {
    const a = await signIn();
    const b = await signIn();
    const home = uuid();
    const theirs = uuid();
    const place = (id: string, name: string) => ({
      op: "upsert",
      entity: "place",
      data: { id, name, latitude: 24.7, longitude: 46.6, radius: 200, updatedAt: 1000 },
    });
    await push(a.token, [place(home, "البيت")]);
    await push(b.token, [place(theirs, "الاستراحة")]);

    fakeAi.answer(
      suggestion({ title: "شراء الخبز", dueTime: "17:00", place: { placeId: home.toUpperCase(), name: "بيتي", trigger: "arrive" } }),
    );
    let res = await call("POST", "/v1/assistant/parse", {
      token: a.token,
      body: { text: "ذكرني أشتري خبز إذا وصلت البيت أو الساعة ٥", now: NOW },
    });
    expect(res.body).toEqual({
      title: "شراء الخبز",
      dueDate: "2026-10-13",
      dueTime: "17:00",
      priority: "none",
      tags: [],
      place: { placeId: home, name: "البيت", trigger: "arrive" },
    });
    const [request] = fakeAi.requests;
    expect(request!.prompt).toContain(`PLACES (id | name):\n${home} | البيت`);
    expect(request!.prompt).not.toContain(theirs);

    // Someone else's place, or one not saved, comes back by name only.
    fakeAi.answer(suggestion({ title: "إطفاء المكيف", place: { placeId: theirs, name: "الاستراحة", trigger: "leave" } }));
    res = await call("POST", "/v1/assistant/parse", { token: a.token, body: { text: "إذا طلعت من الاستراحة طفّ المكيف", now: NOW } });
    expect(res.body).toEqual({ title: "إطفاء المكيف", priority: "none", tags: [], place: { name: "الاستراحة", trigger: "leave" } });
  });

  it("converts Hijri dates on the server with Umm al-Qura", async () => {
    const { token } = await signIn();
    fakeAi.answer(suggestion({ title: "إخراج زكاة الفطر", dueDate: "2027-01-01", dueHijri: { year: null, month: 9, day: 28 } }));
    const res = await call("POST", "/v1/assistant/parse", { token, body: { text: "ذكرني بزكاة الفطر ٢٨ رمضان", now: NOW } });
    expect(res.status).toBe(200);
    expect(hijriParts(res.body.dueDate)).toEqual({ year: 1448, month: 9, day: 28 });
    expect(res.body.dueDate > "2026-10-13").toBe(true);
  });

  it("leaves a task undated, without its prayer or time, when the Hijri date does not exist", async () => {
    const { token } = await signIn();
    // Ramadan 1448 has 29 days in Umm al-Qura.
    expect(dayOfHijri({ year: 1448, month: 9, day: 30 }, "2026-10-13")).toBeNull();
    fakeAi.answer(suggestion({ title: "الاتصال بأبي", dueHijri: { year: null, month: 9, day: 30 }, duePrayer: "maghrib" }));
    let res = await call("POST", "/v1/assistant/parse", { token, body: { text: "ذكرني أتصل بأبي ٣٠ رمضان بعد المغرب", now: NOW } });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ title: "الاتصال بأبي", priority: "none", tags: [] });

    fakeAi.answer(suggestion({ title: "الاتصال بأبي", dueHijri: { year: null, month: 9, day: 30 }, dueTime: "17:00" }));
    res = await call("POST", "/v1/assistant/parse", { token, body: { text: "ذكرني أتصل بأبي ٣٠ رمضان الساعة ٥", now: NOW } });
    expect(res.body).toEqual({ title: "الاتصال بأبي", priority: "none", tags: [] });
  });

  it("returns 503 and gives the request back when the model's answer is unusable", async () => {
    const { token, userId } = await signIn();
    const body = { text: "مهمة", now: NOW };

    fakeAi.answer({ title: 5 });
    let res = await call("POST", "/v1/assistant/parse", { token, body });
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe("ai_unavailable");

    fakeAi.answer(suggestion({ dueTime: "25:00" }));
    expect((await call("POST", "/v1/assistant/parse", { token, body })).status).toBe(503);

    fakeAi.answer(suggestion({ title: "🙂" }));
    expect((await call("POST", "/v1/assistant/parse", { token, body })).status).toBe(503);

    fakeAi.fail(new AiError("Model output is not JSON"));
    res = await call("POST", "/v1/assistant/parse", { token, body });
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe("ai_unavailable");

    expect(fakeAi.requests).toHaveLength(4);
    // None used the quota, but each was paid for, so each counts as failed.
    expect(await usage(userId)).toMatchObject({ requests: 0 });
    expect(await failures(userId)).toBe(4);

    // No model answered (unreachable, an HTTP error): given back, and not a failure either.
    fakeAi.fail(new AiError("Provider returned 503: overloaded", false));
    expect((await call("POST", "/v1/assistant/parse", { token, body })).status).toBe(503);
    expect(await failures(userId)).toBe(4);
  });

  it("rejects bad input and requires sign-in", async () => {
    const { token } = await signIn();
    for (const body of [{}, { text: "  " }, { text: "x".repeat(1001) }, { text: "x", now: "tomorrow" }]) {
      const res = await call("POST", "/v1/assistant/parse", { token, body });
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe("invalid");
    }
    expect((await call("POST", "/v1/assistant/parse", { body: { text: "x" } })).status).toBe(401);
    expect(fakeAi.requests).toEqual([]);
  });
});

describe("monthly quota", () => {
  it("answers 429 with the reset date once the month's requests are used", async () => {
    const { token, userId } = await signIn();
    await env.DB.prepare(`INSERT INTO ai_usage (user_id, month, requests) VALUES (?, ?, ?)`)
      .bind(userId, monthOf(new Date()), 299)
      .run();

    fakeAi.answer(suggestion());
    expect((await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" } })).status).toBe(200);
    expect((await usage(userId))!.requests).toBe(300);

    const res = await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" } });
    expect(res.status).toBe(429);
    expect(res.body.error).toMatchObject({ code: "ai_quota_exceeded", limit: 300, resetsOn: resetDate(new Date()) });
    expect(res.body.error.resetsOn).toMatch(/^\d{4}-\d{2}-01$/);
    expect(fakeAi.requests).toHaveLength(1);

    // Last month's usage does not count.
    const other = await signIn();
    await env.DB.prepare(`INSERT INTO ai_usage (user_id, month, requests) VALUES (?, '2020-01', 1000)`).bind(other.userId).run();
    fakeAi.answer(suggestion());
    expect((await call("POST", "/v1/assistant/parse", { token: other.token, body: { text: "مهمة" } })).status).toBe(200);
  });

  it("lets only one of the requests sent together at the limit through", async () => {
    const { token, userId } = await signIn();
    await env.DB.prepare(`INSERT INTO ai_usage (user_id, month, requests) VALUES (?, ?, ?)`)
      .bind(userId, monthOf(new Date()), 299)
      .run();
    for (let i = 0; i < 5; i++) fakeAi.answer(suggestion());
    const responses = await Promise.all(
      Array.from({ length: 5 }, () => call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" } })),
    );
    expect(responses.map((r) => r.status).sort()).toEqual([200, 429, 429, 429, 429]);
    expect(fakeAi.requests).toHaveLength(1);
    expect((await usage(userId))!.requests).toBe(300);
  });

  it("closes the month once as many paid-for requests failed as the limit allows", async () => {
    const { token, userId } = await signIn();
    const vars = { AI_MONTHLY_LIMIT_PRO: "2" };
    for (let i = 0; i < 2; i++) {
      fakeAi.answer(suggestion({ title: "🙂" }));
      expect((await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: vars })).status).toBe(503);
    }
    expect(await usage(userId)).toMatchObject({ requests: 0 });
    const res = await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: vars });
    expect(res.status).toBe(429);
    expect(res.body.error).toMatchObject({ code: "ai_quota_exceeded", limit: 2 });
    expect(fakeAi.requests).toHaveLength(2);
  });

  it("gives everyone the pro limit while plans are not enforced", async () => {
    const { token } = await signIn();
    const vars = { AI_MONTHLY_LIMIT_FREE: "0", AI_MONTHLY_LIMIT_PRO: "1", SUBSCRIPTIONS_ENFORCED: "false" };
    fakeAi.answer(suggestion());
    expect((await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: vars })).status).toBe(200);
    const res = await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: vars });
    expect(res.status).toBe(429);
    expect(res.body.error).toMatchObject({ code: "ai_quota_exceeded", limit: 1, plan: "pro" });
  });

  it("reads the limit by plan, falling back to AI_MONTHLY_LIMIT, then to 300", () => {
    expect(env.AI_MONTHLY_LIMIT_FREE).toBe("20");
    expect(env.AI_MONTHLY_LIMIT_PRO).toBe("300");
    const vars = { AI_MONTHLY_LIMIT: "50", AI_MONTHLY_LIMIT_FREE: "20", AI_MONTHLY_LIMIT_PRO: "400" };
    expect(planMonthlyLimit(vars, "free")).toBe(20);
    expect(planMonthlyLimit(vars, "pro")).toBe(400);
    expect(planMonthlyLimit({ AI_MONTHLY_LIMIT: "50" }, "free")).toBe(50);
    expect(planMonthlyLimit({ AI_MONTHLY_LIMIT: "50", AI_MONTHLY_LIMIT_PRO: " " }, "pro")).toBe(50);
    expect(planMonthlyLimit({ AI_MONTHLY_LIMIT: "50", AI_MONTHLY_LIMIT_FREE: "-1" }, "free")).toBe(50);
    expect(planMonthlyLimit({ AI_MONTHLY_LIMIT: "" }, "pro")).toBe(DEFAULT_MONTHLY_LIMIT);
    expect(planMonthlyLimit({ AI_MONTHLY_LIMIT: "50", AI_MONTHLY_LIMIT_FREE: "0" }, "free")).toBe(0);
  });
});

const MIN = 60_000;
const DAY_MS = 24 * 60 * MIN;

async function windows(userId: string) {
  const { results } = await env.DB.prepare(`SELECT scope, window_start, requests FROM ai_rate WHERE user_id = ? ORDER BY scope`)
    .bind(userId)
    .all<{ scope: string; window_start: number; requests: number }>();
  return Object.fromEntries(results.map((r) => [r.scope, r.requests]));
}

async function globalToday() {
  const start = Math.floor(Date.now() / DAY_MS) * DAY_MS;
  const row = await env.DB.prepare(`SELECT requests FROM ai_rate WHERE user_id = '' AND scope = 'global' AND window_start = ?`)
    .bind(start)
    .first<{ requests: number }>();
  return row?.requests ?? 0;
}

const secondsToUtcMidnight = () => Math.ceil((Math.floor(Date.now() / DAY_MS) * DAY_MS + DAY_MS - Date.now()) / 1000);

describe("short-window limits", () => {
  it("answers 429 ai_rate_limited for the day, without calling the model or using the month", async () => {
    const { token, userId } = await signIn();
    const vars = { AI_DAILY_LIMIT_PRO: "2" };
    for (let i = 0; i < 2; i++) {
      fakeAi.answer(suggestion());
      expect((await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: vars })).status).toBe(200);
    }
    const res = await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: vars });
    expect(res.status).toBe(429);
    expect(res.body.error).toMatchObject({ code: "ai_rate_limited", scope: "day", limit: 2 });
    expect(Number.isInteger(res.body.error.retryAfter)).toBe(true);
    expect(Math.abs(res.body.error.retryAfter - secondsToUtcMidnight())).toBeLessThanOrEqual(2);
    expect(res.headers.get("Retry-After")).toBe(String(res.body.error.retryAfter));
    expect(fakeAi.requests).toHaveLength(2);
    // The refused request counts nowhere.
    expect((await usage(userId))!.requests).toBe(2);
    expect((await windows(userId)).day).toBe(2);
  });

  it("answers the minute's refusal with the seconds left in it", async () => {
    // "0" refuses every request, so this does not depend on where in the minute the test runs.
    const { token } = await signIn();
    const refused = await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: { AI_MINUTE_LIMIT_PRO: "0" } });
    expect(refused.status).toBe(429);
    expect(refused.body.error).toMatchObject({ code: "ai_rate_limited", scope: "minute", limit: 0 });
    expect(refused.body.error.retryAfter).toBeGreaterThanOrEqual(1);
    expect(refused.body.error.retryAfter).toBeLessThanOrEqual(60);
    expect(refused.headers.get("Retry-After")).toBe(String(refused.body.error.retryAfter));
    expect(fakeAi.requests).toEqual([]);
  });

  it("answers 503 ai_busy once everyone's daily cap is reached", async () => {
    const a = await signIn();
    const b = await signIn();
    const vars = { AI_GLOBAL_DAILY_LIMIT: String((await globalToday()) + 1) };
    fakeAi.answer(suggestion());
    expect((await call("POST", "/v1/assistant/parse", { token: a.token, body: { text: "مهمة" }, env: vars })).status).toBe(200);
    for (const user of [a, b]) {
      const res = await call("POST", "/v1/assistant/parse", { token: user.token, body: { text: "مهمة" }, env: vars });
      expect(res.status).toBe(503);
      expect(res.body.error).toMatchObject({ code: "ai_busy" });
      expect(Math.abs(res.body.error.retryAfter - secondsToUtcMidnight())).toBeLessThanOrEqual(2);
      expect(res.headers.get("Retry-After")).toBe(String(res.body.error.retryAfter));
    }
    expect(fakeAi.requests).toHaveLength(1);
    expect(await windows(b.userId)).toEqual({});
    // "0" turns the assistant off for everyone.
    const off = await call("POST", "/v1/assistant/parse", { token: b.token, body: { text: "مهمة" }, env: { AI_GLOBAL_DAILY_LIMIT: "0" } });
    expect(off.body.error.code).toBe("ai_busy");
  });

  it("gives the windows back when the month refuses, and the day's when no model was paid", async () => {
    const { token, userId } = await signIn();
    fakeAi.fail(new AiError("Provider returned 503: overloaded", false));
    expect((await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" } })).status).toBe(503);
    // Unpaid: the minute keeps it (it limits the pace), the day and the global day do not.
    expect(await windows(userId)).toEqual({ minute: 1, day: 0 });

    fakeAi.answer({ title: 5 }); // paid for, unusable
    expect((await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" } })).status).toBe(503);
    expect((await windows(userId)).day).toBe(1);

    await env.DB.prepare(`INSERT INTO ai_usage (user_id, month, requests) VALUES (?, ?, 300)
      ON CONFLICT (user_id, month) DO UPDATE SET requests = 300`)
      .bind(userId, monthOf(new Date()))
      .run();
    const res = await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" } });
    expect(res.status).toBe(429);
    expect(res.body.error.code).toBe("ai_quota_exceeded");
    expect((await windows(userId)).day).toBe(1);
    expect(fakeAi.requests).toHaveLength(2);
  });

  it("gives a free user the free limits, and keeps the assistant pro-only when one is 0", async () => {
    const { token } = await signIn();
    const free = { SUBSCRIPTIONS_ENFORCED: "true", AI_MONTHLY_LIMIT_FREE: "20" };
    fakeAi.answer(suggestion());
    expect((await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: { ...free, AI_DAILY_LIMIT_FREE: "1" } })).status).toBe(200);
    const res = await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: { ...free, AI_DAILY_LIMIT_FREE: "1" } });
    expect(res.status).toBe(429);
    expect(res.body.error).toMatchObject({ code: "ai_rate_limited", scope: "day", limit: 1 });

    for (const zero of [{ AI_DAILY_LIMIT_FREE: "0" }, { AI_MINUTE_LIMIT_FREE: "0" }]) {
      const closed = await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" }, env: { ...free, ...zero } });
      expect(closed.status).toBe(403);
      expect(closed.body.error.code).toBe("pro_required");
    }
    expect(fakeAi.requests).toHaveLength(1);
  });

  it("takes a request from all three windows or from none, and lets only what fits through together", async () => {
    const user = uuid();
    const now = Date.UTC(2031, 0, 5, 10, 30, 15, 500);
    const minuteStart = Date.UTC(2031, 0, 5, 10, 30);
    const limits = { minute: 2, day: 3, global: 1_000_000 };

    const together = await Promise.all(Array.from({ length: 5 }, () => takeRequest(env.DB, user, limits, now)));
    expect(together.filter((r) => r.allowed)).toHaveLength(2);
    const refused = together.find((r) => !r.allowed)!;
    expect(refused).toEqual({ allowed: false, refusal: { scope: "minute", limit: 2, retryAfter: 45 } });
    // Both requests counted in every window; the refused ones in none.
    expect(await windows(user)).toEqual({ minute: 2, day: 2 });

    // The next minute: one more fits the day, then the day is full until 00:00 UTC.
    expect((await takeRequest(env.DB, user, limits, now + MIN)).allowed).toBe(true);
    const full = await takeRequest(env.DB, user, limits, now + MIN);
    expect(full).toEqual({ allowed: false, refusal: { scope: "day", limit: 3, retryAfter: Math.ceil((Date.UTC(2031, 0, 6) - (now + MIN)) / 1000) } });

    // Given back: all windows, or only the day's.
    const taken = await takeRequest(env.DB, user, { ...limits, day: 10 }, now + 2 * MIN);
    expect(taken.allowed).toBe(true);
    if (!taken.allowed) return;
    expect(taken.hold).toEqual({ userId: user, minuteStart: minuteStart + 2 * MIN, dayStart: Date.UTC(2031, 0, 5) });
    await releaseRequest(env.DB, taken.hold, "spend");
    const rows = await env.DB.prepare(`SELECT scope, window_start, requests FROM ai_rate WHERE user_id = ? AND scope = 'minute' ORDER BY window_start`)
      .bind(user)
      .all<{ requests: number }>();
    expect(rows.results.map((r) => r.requests)).toEqual([2, 1, 1]);
    expect((await windows(user)).day).toBe(3);
    await releaseRequest(env.DB, taken.hold, "all");
    expect((await windows(user)).day).toBe(2);
  });

  it("deletes ended windows from the cron, and a user's with their account", async () => {
    const user = uuid();
    const now = Date.UTC(2032, 2, 1, 8, 0, 30);
    const limits = { minute: 5, day: 5, global: 1_000_000 };
    await takeRequest(env.DB, user, limits, now - DAY_MS); // yesterday
    await takeRequest(env.DB, user, limits, now - MIN); // the minute before
    await takeRequest(env.DB, user, limits, now);
    const controller = createScheduledController({ scheduledTime: now, cron: "*/5 * * * *" });
    const ctx = createExecutionContext();
    await worker.scheduled(controller, env, ctx);
    await waitOnExecutionContext(ctx);
    const left = await env.DB.prepare(`SELECT scope, window_start FROM ai_rate WHERE user_id = ? OR (user_id = '' AND window_start >= ?) ORDER BY scope`)
      .bind(user, Date.UTC(2032, 2, 1) - DAY_MS)
      .all<{ scope: string; window_start: number }>();
    expect(left.results).toEqual([
      { scope: "day", window_start: Date.UTC(2032, 2, 1) },
      { scope: "global", window_start: Date.UTC(2032, 2, 1) },
      { scope: "minute", window_start: Date.UTC(2032, 2, 1, 8, 0) },
    ]);
    await deleteEndedRateWindows(env.DB, now + DAY_MS);
    expect(await windows(user)).toEqual({});

    const { token, userId } = await signIn();
    fakeAi.answer(suggestion());
    expect((await call("POST", "/v1/assistant/parse", { token, body: { text: "مهمة" } })).status).toBe(200);
    const global = await globalToday();
    expect((await deleteAccount(token)).status).toBe(204);
    expect(await windows(userId)).toEqual({});
    expect(await globalToday()).toBe(global);
  });

  it("reads the limits by plan, falling back to the defaults", () => {
    expect(env.AI_MINUTE_LIMIT_FREE).toBe("5");
    expect(env.AI_MINUTE_LIMIT_PRO).toBe("10");
    expect(env.AI_DAILY_LIMIT_FREE).toBe("10");
    expect(env.AI_DAILY_LIMIT_PRO).toBe("60");
    expect(env.AI_GLOBAL_DAILY_LIMIT).toBe("2000");
    expect(planRateLimits(env, "free")).toEqual({ minute: 5, day: 10, global: 2000 });
    expect(planRateLimits(env, "pro")).toEqual({ minute: 10, day: 60, global: 2000 });
    expect(planRateLimits({}, "free")).toEqual({ minute: 5, day: 10, global: 2000 });
    expect(planRateLimits({ AI_MINUTE_LIMIT_PRO: "x", AI_DAILY_LIMIT_PRO: "-3", AI_GLOBAL_DAILY_LIMIT: " " }, "pro")).toEqual({
      minute: DEFAULT_RATE_LIMITS.minute.pro,
      day: DEFAULT_RATE_LIMITS.day.pro,
      global: DEFAULT_RATE_LIMITS.global,
    });
    expect(planRateLimits({ AI_MINUTE_LIMIT_FREE: "0", AI_DAILY_LIMIT_FREE: "7", AI_GLOBAL_DAILY_LIMIT: "0" }, "free")).toEqual({
      minute: 0,
      day: 7,
      global: 0,
    });
  });
});

describe("POST /v1/assistant/breakdown", () => {
  it("suggests short subtasks for a visible task without saving them", async () => {
    const { token } = await signIn();
    const project = await createProject(token, "الانتقال");
    const task = await createTask(token, { title: "تجهيز الشقة الجديدة", notes: "قبل نهاية الشهر", projectId: project });
    await createTask(token, { title: "نقل العفش", parentId: task, projectId: project });

    fakeAi.answer({
      subtasks: [
        "1. حجز شركة نقل",
        "تنظيف الشقة 🧹",
        "حجز شركة نقل",
        "تجهيز الشقة الجديدة",
        "توصيل الكهرباء والماء.",
        "شراء الستائر",
        "تركيب الإنترنت",
        "فرش الغرف",
        "تغيير الأقفال",
        "ترتيب المطبخ",
        "تعليق اللوحات",
      ],
    });
    const res = await call("POST", "/v1/assistant/breakdown", { token, body: { taskId: task.toUpperCase() } });
    expect(res.status).toBe(200);
    expect(res.body.subtasks).toEqual([
      "حجز شركة نقل",
      "تنظيف الشقة",
      "توصيل الكهرباء والماء",
      "شراء الستائر",
      "تركيب الإنترنت",
      "فرش الغرف",
      "تغيير الأقفال",
      "ترتيب المطبخ",
    ]);
    const prompt = fakeAi.requests[0]!.prompt;
    expect(prompt).toContain("<title>\nتجهيز الشقة الجديدة\n</title>");
    expect(prompt).toContain("قبل نهاية الشهر");
    expect(prompt).toContain("- نقل العفش");
    expect(prompt).toContain("الانتقال");

    const subtasks = await call("GET", `/v1/tasks?projectId=${project}`, { token });
    expect(subtasks.body.tasks).toHaveLength(2);
  });

  it("is 404 for someone else's task and 400 for a bad id, without calling the model", async () => {
    const a = await signIn();
    const b = await signIn();
    const task = await createTask(a.token, { title: "خاصة" });
    const res = await call("POST", "/v1/assistant/breakdown", { token: b.token, body: { taskId: task } });
    expect(res.status).toBe(404);
    expect((await call("POST", "/v1/assistant/breakdown", { token: b.token, body: { taskId: uuid() } })).status).toBe(404);
    expect((await call("POST", "/v1/assistant/breakdown", { token: b.token, body: { taskId: "nope" } })).status).toBe(400);
    expect(fakeAi.requests).toEqual([]);
  });

  it("returns 503 when the model gives fewer than three subtasks", async () => {
    const { token, userId } = await signIn();
    const task = await createTask(token, { title: "كتابة التقرير" });
    fakeAi.answer({ subtasks: ["جمع البيانات", "جمع البيانات", "كتابة التقرير"] });
    const res = await call("POST", "/v1/assistant/breakdown", { token, body: { taskId: task } });
    expect(res.status).toBe(503);
    expect(await usage(userId)).toMatchObject({ requests: 0 });
    expect(await failures(userId)).toBe(1);
  });
});

describe("GET /v1/assistant/summary", () => {
  it("summarises the day from the agenda data only", async () => {
    const { token, userId } = await signIn();
    await call("PATCH", "/v1/me", {
      token,
      body: { settings: { timeZone: "Asia/Riyadh", location: { latitude: 24.7136, longitude: 46.6753 } } },
    });
    const today = dayIn("Asia/Riyadh");
    await createTask(token, { title: "اجتماع الفريق", dueDate: today, dueTime: "10:00", priority: 3 });
    await createTask(token, { title: "زيارة الوالدة", dueDate: today, duePrayer: "maghrib", duePrayerOffset: 30 });
    await createTask(token, { title: "مهمة منجزة", dueDate: today, status: "done" });
    await createTask(token, { title: "تجديد الإقامة", dueDate: addDays(today, -2) });
    await createTask(token, { title: "مهمة الغد", dueDate: addDays(today, 1) });

    fakeAi.answer({ text: "لديك مهمتان اليوم ☀️: **اجتماع الفريق** و«زيارة الوالدة»، ومهمة متأخرة: تجديد الإقامة." });
    const res = await call("GET", "/v1/assistant/summary", { token });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      date: today,
      text: "لديك مهمتان اليوم : اجتماع الفريق و«زيارة الوالدة»، ومهمة متأخرة: تجديد الإقامة.",
    });

    const prompt = fakeAi.requests[0]!.prompt;
    const agenda = JSON.parse(prompt.slice(prompt.indexOf("{")));
    expect(agenda.counts).toEqual({ dueOpen: 2, dueDone: 1, overdue: 1 });
    expect(agenda.dueToday.map((t: { title: string }) => t.title)).toEqual(["اجتماع الفريق", "زيارة الوالدة"]);
    expect(agenda.dueToday[0]).toMatchObject({ priority: "high", time: "10:00" });
    expect(agenda.dueToday[1]).toMatchObject({ prayer: "بعد المغرب بـ٣٠ د", prayerTime: expect.stringMatching(/^\d{2}:\d{2}$/) });
    expect(agenda.overdue).toEqual([expect.objectContaining({ title: "تجديد الإقامة" })]);
    expect(prompt).not.toContain("مهمة الغد");
    expect(prompt).not.toContain("مهمة منجزة");
    expect(fakeAi.requests[0]!.system).toContain("never add, rename, merge or guess a task");
    expect((await usage(userId))!.requests).toBe(1);
  });

  it("answers an empty day without the model, and validates the date", async () => {
    const { token, userId } = await signIn();
    const res = await call("GET", "/v1/assistant/summary?date=2026-10-20", { token });
    expect(res.body).toEqual({ date: "2026-10-20", text: "لا مهام لهذا اليوم ولا مهام متأخرة. يومك متاح." });
    expect(fakeAi.requests).toEqual([]);
    expect(await usage(userId)).toBeNull();
    expect((await call("GET", "/v1/assistant/summary?date=13-10-2026", { token })).status).toBe(400);
  });
});

describe("Hijri conversion", () => {
  it("finds the Gregorian day of an Umm al-Qura date", () => {
    expect(dayOfHijri({ year: 1448, month: 5, day: 2 }, "2026-10-13")).toBe("2026-10-13");
    expect(dayOfHijri({ month: 5, day: 2 }, "2026-10-13")).toBe("2026-10-13");
    // Without a year, a date already past this year is next year's.
    const next = dayOfHijri({ month: 5, day: 1 }, "2026-10-13")!;
    expect(hijriParts(next)).toEqual({ year: 1449, month: 5, day: 1 });
    for (const month of [1, 4, 9, 10, 12]) {
      const day = dayOfHijri({ month, day: 15 }, "2026-10-13")!;
      expect(hijriParts(day)).toMatchObject({ month, day: 15 });
    }
    expect(dayOfHijri({ month: 13, day: 1 }, "2026-10-13")).toBeNull();
  });
});

// MARK: Providers

interface Captured {
  url: string;
  headers: Headers;
  body: Record<string, any>;
}

function stubFetch(response: unknown, status = 200) {
  const calls: Captured[] = [];
  const doFetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), headers: new Headers(init?.headers), body: JSON.parse(String(init?.body)) });
    return new Response(JSON.stringify(response), { status, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  return { calls, doFetch };
}

const REQUEST = {
  name: "parse_task",
  system: "System rules",
  prompt: "<note>\nمهمة\n</note>",
  schema: { type: "object", additionalProperties: false, required: ["title"], properties: { title: { type: "string" } } },
};

describe("AnthropicProvider", () => {
  it("calls the Messages API through the gateway with structured output", async () => {
    const { calls, doFetch } = stubFetch({
      stop_reason: "end_turn",
      content: [
        { type: "thinking", thinking: "", signature: "x" },
        { type: "text", text: '{"title":"مهمة"}' },
      ],
      usage: { input_tokens: 321, output_tokens: 12 },
    });
    const provider = new AnthropicProvider({ apiKey: "sk-ant-test", gatewayUrl: `${GATEWAY}/`, gatewayToken: "gw-token", fetch: doFetch });
    const result = await provider.complete(REQUEST);
    expect(result).toEqual({ json: { title: "مهمة" }, usage: { input: 321, output: 12 } });

    const [req] = calls;
    expect(req!.url).toBe(`${GATEWAY}/anthropic/v1/messages`);
    expect(req!.url).not.toContain("sk-ant-test");
    expect(req!.headers.get("x-api-key")).toBe("sk-ant-test");
    expect(req!.headers.get("anthropic-version")).toBe("2023-06-01");
    expect(req!.headers.get("cf-aig-authorization")).toBe("Bearer gw-token");
    // The gateway never logs the user's text (the privacy policy).
    expect(req!.headers.get("cf-aig-collect-log")).toBe("false");
    expect(req!.headers.get("authorization")).toBeNull();
    expect(req!.body).toEqual({
      model: ANTHROPIC_MODEL,
      max_tokens: 4096,
      system: "System rules",
      messages: [{ role: "user", content: REQUEST.prompt }],
      output_config: { effort: "low", format: { type: "json_schema", schema: REQUEST.schema } },
    });
    expect(ANTHROPIC_MODEL).toBe("claude-haiku-5-5");
  });

  it("fails on refusals, truncation, HTTP errors and non-JSON text", async () => {
    const cases: [unknown, number][] = [
      [{ stop_reason: "refusal", content: [] }, 200],
      [{ stop_reason: "max_tokens", content: [{ type: "text", text: '{"title":' }] }, 200],
      [{ type: "error", error: { type: "overloaded_error" } }, 529],
      [{ stop_reason: "end_turn", content: [{ type: "text", text: "مرحبا" }] }, 200],
    ];
    for (const [response, status] of cases) {
      const { doFetch } = stubFetch(response, status);
      const provider = new AnthropicProvider({ apiKey: "k", gatewayUrl: GATEWAY, fetch: doFetch });
      await expect(provider.complete(REQUEST)).rejects.toBeInstanceOf(AiError);
    }
  });
});

describe("DeepSeekProvider", () => {
  it("calls chat completions through the gateway in JSON mode", async () => {
    const { calls, doFetch } = stubFetch({
      choices: [{ finish_reason: "stop", message: { role: "assistant", content: '```json\n{"title":"مهمة"}\n```' } }],
      usage: { prompt_tokens: 200, completion_tokens: 9 },
    });
    const provider = new DeepSeekProvider({ apiKey: "sk-ds-test", gatewayUrl: GATEWAY, fetch: doFetch });
    expect(await provider.complete(REQUEST)).toEqual({ json: { title: "مهمة" }, usage: { input: 200, output: 9 } });

    const [req] = calls;
    expect(req!.url).toBe(`${GATEWAY}/deepseek/chat/completions`);
    expect(req!.url).not.toContain("sk-ds-test");
    expect(req!.headers.get("authorization")).toBe("Bearer sk-ds-test");
    expect(req!.headers.get("x-api-key")).toBeNull();
    expect(req!.headers.get("cf-aig-authorization")).toBeNull();
    expect(req!.headers.get("cf-aig-collect-log")).toBe("false");
    expect(req!.body).toMatchObject({ model: "deepseek-chat", max_tokens: 4096, response_format: { type: "json_object" } });
    expect(req!.body.messages).toHaveLength(2);
    expect(req!.body.messages[0].role).toBe("system");
    expect(req!.body.messages[0].content).toContain("System rules");
    expect(req!.body.messages[0].content).toContain(JSON.stringify(REQUEST.schema));
    expect(req!.body.messages[1]).toEqual({ role: "user", content: REQUEST.prompt });
  });

  it("never asks for more than MAX_OUTPUT_TOKENS", async () => {
    const { calls, doFetch } = stubFetch({ choices: [{ finish_reason: "stop", message: { content: '{"title":"مهمة"}' } }] });
    const provider = new DeepSeekProvider({ apiKey: "k", gatewayUrl: GATEWAY, fetch: doFetch });
    await provider.complete({ ...REQUEST, maxTokens: 1_000_000 });
    await provider.complete({ ...REQUEST, maxTokens: 512 });
    expect(calls.map((c) => c.body.max_tokens)).toEqual([MAX_OUTPUT_TOKENS, 512]);
    expect(MAX_OUTPUT_TOKENS).toBe(4096);
  });

  it("fails when the answer is cut off", async () => {
    const { doFetch } = stubFetch({ choices: [{ finish_reason: "length", message: { content: '{"ti' } }] });
    const provider = new DeepSeekProvider({ apiKey: "k", gatewayUrl: GATEWAY, fetch: doFetch });
    await expect(provider.complete(REQUEST)).rejects.toBeInstanceOf(AiError);
  });
});

describe("providerFromEnv", () => {
  const base = { AI_GATEWAY_URL: GATEWAY, AI_MONTHLY_LIMIT: "300" } as Env;

  it("switches provider by AI_PROVIDER and uses the matching secret", async () => {
    const anthropic = stubFetch({ stop_reason: "end_turn", content: [{ type: "text", text: "{}" }], usage: {} });
    const a = providerFromEnv({ ...base, AI_PROVIDER: "anthropic", ANTHROPIC_API_KEY: "ka", DEEPSEEK_API_KEY: "kd" }, anthropic.doFetch);
    expect(a).toBeInstanceOf(AnthropicProvider);
    await a.complete(REQUEST);
    expect(anthropic.calls[0]!.url).toBe(`${GATEWAY}/anthropic/v1/messages`);
    expect(anthropic.calls[0]!.headers.get("x-api-key")).toBe("ka");

    const deepseek = stubFetch({ choices: [{ finish_reason: "stop", message: { content: "{}" } }] });
    const d = providerFromEnv({ ...base, AI_PROVIDER: "DeepSeek", ANTHROPIC_API_KEY: "ka", DEEPSEEK_API_KEY: "kd" }, deepseek.doFetch);
    expect(d).toBeInstanceOf(DeepSeekProvider);
    await d.complete(REQUEST);
    expect(deepseek.calls[0]!.headers.get("authorization")).toBe("Bearer kd");
  });

  it("fails as unavailable when the key or provider is missing", async () => {
    await expect(providerFromEnv({ ...base, AI_PROVIDER: "anthropic" }).complete(REQUEST)).rejects.toBeInstanceOf(AiError);
    await expect(providerFromEnv({ ...base, AI_PROVIDER: "deepseek" }).complete(REQUEST)).rejects.toBeInstanceOf(AiError);
    await expect(providerFromEnv({ ...base, AI_PROVIDER: "other", ANTHROPIC_API_KEY: "k" }).complete(REQUEST)).rejects.toBeInstanceOf(AiError);
  });

  it("is configured in wrangler vars without any key", () => {
    expect(env.AI_PROVIDER).toBe("deepseek");
    expect(env.AI_GATEWAY_URL).toBe(GATEWAY);
    expect(env.AI_MONTHLY_LIMIT).toBe("300");
  });
});
