-- Short-window assistant limits (src/ai/limits.ts), checked before the model is called, beside
-- the monthly quota in ai_usage: requests per user per minute and per UTC day, by plan, and a
-- cap per UTC day across all users that stops a bill spike whatever its cause.
-- See api/DEVELOPMENT.md, «الحدود القصيرة».
--
-- One row per window: scope 'minute' or 'day' for a user, or 'global' with user_id ''.
-- window_start is the window's first Unix ms (the minute, or 00:00 UTC). A request is taken
-- from all three of its windows in one statement, or from none. Old windows are deleted by the
-- 5-minute cron, and a user's rows with their account.
CREATE TABLE ai_rate (
  user_id TEXT NOT NULL,
  scope TEXT NOT NULL CHECK (scope IN ('minute', 'day', 'global')),
  window_start INTEGER NOT NULL,
  requests INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, scope, window_start)
);
-- What the cron's cleanup reads.
CREATE INDEX ai_rate_window ON ai_rate(scope, window_start);
