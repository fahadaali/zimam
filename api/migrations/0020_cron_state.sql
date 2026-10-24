-- What the 5-minute cron keeps between runs (src/push/reminders.ts). See api/DEVELOPMENT.md,
-- «إشعارات الخادم».

-- Where each job stopped, in Unix ms: 'reminder_pushes' is the end of the last window the reminder
-- pushes finished. A run that hits its cap, or fails, leaves it at the first reminder it did not
-- send, and the next run starts there (at most an hour back) instead of dropping the rest.
-- Claims in reminder_pushes keep a window read twice from sending twice.
CREATE TABLE cron_cursors (
  name TEXT PRIMARY KEY,
  until_at INTEGER NOT NULL
);

-- Each run deletes the sessions that expired (180 days unused, src/auth/sessions.ts), and with
-- them their devices and realtime tickets (ON DELETE CASCADE), so an install signed out by
-- expiry gets no more pushes.
CREATE INDEX sessions_expires ON sessions(expires_at);
