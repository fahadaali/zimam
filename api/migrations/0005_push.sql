-- Reminder pushes over APNs, for what lies beyond the app's local notification window
-- (iOS keeps 64 pending local notifications; the app schedules the next 14 days).
-- See api/DEVELOPMENT.md, «إشعارات الخادم».

-- One row per app install: its APNs device token, tied to the session that registered
-- it, so signing out (or deleting the account) removes it with the session.
-- last_seen_at is the last time this install pulled changes (GET /v1/sync); the app
-- reschedules its local window right after each pull. 0 = registered, not pulled yet.
CREATE TABLE devices (
  token TEXT PRIMARY KEY, -- APNs device token, lowercase hex
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
  platform TEXT NOT NULL CHECK (platform IN ('ios', 'macos', 'watchos')),
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  bundle_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX devices_user ON devices(user_id);
CREATE INDEX devices_session ON devices(session_hash);

-- Every reminder push claimed by the cron, so none is sent twice. One per user, task
-- and minute, like the app's planner (a reminder that repeats the task's own prayer
-- anchor gives one notification). Rows older than 30 days are cleared by the cron.
CREATE TABLE reminder_pushes (
  user_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  fire_minute INTEGER NOT NULL, -- fire time in Unix minutes
  source TEXT NOT NULL, -- the planner's id: 'reminder-<id>', 'reminder-<id>@<day>', 'task-<id>@<day>'
  sent_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, task_id, fire_minute)
);
CREATE INDEX reminder_pushes_sent ON reminder_pushes(sent_at);

-- The APNs provider token (an ES256 JWT, valid for an hour), shared by every isolate:
-- Apple rejects refreshing it more than once every 20 minutes. Not the signing key,
-- which stays in Worker secrets.
CREATE TABLE apns_tokens (
  key_id TEXT PRIMARY KEY,
  token TEXT NOT NULL,
  issued_at INTEGER NOT NULL
);

-- What the cron reads every 5 minutes.
CREATE INDEX reminders_time_due ON reminders(unixepoch(at)) WHERE kind = 'time' AND deleted_at IS NULL;
CREATE INDEX reminders_prayer ON reminders(task_id) WHERE kind = 'prayer' AND deleted_at IS NULL;
CREATE INDEX tasks_prayer_anchor ON tasks(due_date) WHERE due_prayer IS NOT NULL AND deleted_at IS NULL;
