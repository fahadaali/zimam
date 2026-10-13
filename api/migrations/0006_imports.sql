-- Imports from other apps (Todoist, TickTick, Google Tasks, CSV), run on the
-- zimam-imports queue. See api/DEVELOPMENT.md, «الاستيراد».
--
-- One row per import. Nothing secret is stored: a provider token travels in the
-- first queue message only, and the uploaded file (then the parsed data) lives in
-- R2 under file_key until the job ends. Records are linked to their source through
-- external_refs (0001), so importing the same data again updates instead of copying.
CREATE TABLE import_jobs (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source TEXT NOT NULL, -- 'todoist-csv', 'todoist-api', 'ticktick-csv', 'google-tasks', 'csv'
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'done', 'failed')),
  file_name TEXT,
  file_size INTEGER,
  -- R2 key of the upload, then of the parsed data; NULL once the job ends.
  file_key TEXT,
  total INTEGER NOT NULL DEFAULT 0, -- items to apply (projects, sections, tasks, reminders)
  processed INTEGER NOT NULL DEFAULT 0, -- items handled so far; the queue cursor
  counts TEXT NOT NULL DEFAULT '{}', -- {"task": {"created": 3, "updated": 1, ...}, ...}
  errors TEXT NOT NULL DEFAULT '[]', -- per-item problems, Arabic, capped
  warnings TEXT NOT NULL DEFAULT '[]', -- what was kept as a note instead of mapped, Arabic, capped
  error_code TEXT, -- why the whole job failed: stable English code
  error_message TEXT, -- and its Arabic text, shown by the app
  lease_until INTEGER, -- a consumer is working on the current chunk until then
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  finished_at INTEGER
);
CREATE INDEX import_jobs_user ON import_jobs(user_id, created_at);
