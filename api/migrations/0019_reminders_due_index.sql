-- The index the reminder cron reads every 5 minutes for timed reminders (src/push/reminders.ts).
-- Its query covers 'time' reminders and 'location' ones with a time («أيهما أسبق», 0016), so it
-- cannot say `kind = 'time'`, and the old index (`WHERE kind = 'time'`, 0005 and 0018) went unused:
-- SQLite reads a partial index only when the query implies its condition, and every run scanned
-- the whole table. This one's condition is in the query as it is. Reminders without `at` (prayer,
-- relative, a place alone) index as NULL and never fall in the range.
--
-- A later rebuild of the reminders table (like 0018's) recreates this index, not reminders_time_due.
CREATE INDEX reminders_at_due ON reminders(unixepoch(at)) WHERE deleted_at IS NULL;
DROP INDEX IF EXISTS reminders_time_due;
