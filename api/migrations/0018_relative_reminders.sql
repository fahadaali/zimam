-- Reminders relative to their task's own time («عند الموعد», «قبل ١٥ د», «قبل يوم»): kind
-- 'relative', with offset_minutes from the task's clock time, its prayer, or 09:00 of its day when
-- it has neither, at or before it. They move with the task. See api/DEVELOPMENT.md, «إشعارات الخادم».
--
-- Synced only to apps that ask for them (`include=relative`), since older apps decode `kind`
-- strictly (src/data/pull.ts).
--
-- SQLite cannot change a CHECK constraint, so the table is rebuilt with the same columns and indexes.
PRAGMA defer_foreign_keys = true;

CREATE TABLE reminders_new (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  task_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('time', 'prayer', 'location', 'relative')),
  at TEXT,
  prayer TEXT CHECK (prayer IN ('fajr', 'dhuhr', 'asr', 'maghrib', 'isha')),
  offset_minutes INTEGER,
  location TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  fired_at INTEGER
);
INSERT INTO reminders_new (id, user_id, task_id, kind, at, prayer, offset_minutes, location, created_at, updated_at, deleted_at, fired_at)
  SELECT id, user_id, task_id, kind, at, prayer, offset_minutes, location, created_at, updated_at, deleted_at, fired_at FROM reminders;
DROP TABLE reminders;
ALTER TABLE reminders_new RENAME TO reminders;

CREATE INDEX reminders_task ON reminders(task_id);
CREATE INDEX reminders_time_due ON reminders(unixepoch(at)) WHERE kind = 'time' AND deleted_at IS NULL;
CREATE INDEX reminders_prayer ON reminders(task_id) WHERE kind = 'prayer' AND deleted_at IS NULL;
CREATE INDEX reminders_relative ON reminders(task_id) WHERE kind = 'relative' AND deleted_at IS NULL;

PRAGMA defer_foreign_keys = false;

-- A task anchored to a prayer used to notify everyone who has it by itself. That is now a
-- personal «عند الموعد» (relative, 0), which each of them can remove: one for the owner of an
-- inbox task, and one for each member of a shared project.
WITH anchored AS (
  SELECT id, owner_id, project_id FROM tasks
  WHERE due_prayer IS NOT NULL AND deleted_at IS NULL AND status <> 'done'
),
audience AS (
  SELECT id AS task_id, owner_id AS user_id FROM anchored WHERE project_id IS NULL
  UNION
  SELECT a.id, m.user_id FROM anchored a JOIN project_members m ON m.project_id = a.project_id
),
fresh AS (
  SELECT task_id, user_id, lower(hex(randomblob(16))) AS h FROM audience
)
INSERT INTO reminders (id, user_id, task_id, kind, offset_minutes, created_at, updated_at)
  SELECT substr(h, 1, 8) || '-' || substr(h, 9, 4) || '-4' || substr(h, 14, 3) || '-8' || substr(h, 18, 3) || '-' || substr(h, 21, 12),
         user_id, task_id, 'relative', 0, CAST(strftime('%s', 'now') AS INTEGER) * 1000, CAST(strftime('%s', 'now') AS INTEGER) * 1000
  FROM fresh;

INSERT INTO changes (entity, entity_id, project_id, user_id, at)
  SELECT 'reminder', id, NULL, user_id, created_at FROM reminders WHERE kind = 'relative';
