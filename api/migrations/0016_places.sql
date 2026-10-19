-- Saved places («أماكني»): «البيت»، «العمل»، «الاستراحة», named by the user and reused by
-- location reminders. See api/DEVELOPMENT.md, «الأماكن».
--
-- Personal like reminders: synced to their owner only, and only to apps that ask for them
-- (`include=place`), since older apps decode entities strictly. A reminder keeps its own copy of
-- the place in `reminders.location` (with `placeId`), so it works in apps that predate places and
-- after the place is deleted; editing a place rewrites that copy (src/data/mutations.ts).
CREATE TABLE places (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  radius REAL NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE INDEX places_user ON places(user_id);

-- A location reminder with a time too (`at`) fires once, at whichever comes first. When the
-- place comes first the device sets fired_at, so other devices and the server's pushes
-- (src/push/reminders.ts) skip the time. Unix milliseconds.
ALTER TABLE reminders ADD COLUMN fired_at INTEGER;
