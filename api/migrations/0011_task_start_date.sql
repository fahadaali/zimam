-- A task's start day, for tasks that span days: the calendar draws them as a bar and the
-- timeline («المخطط الزمني») from start_date to due_date. See api/DEVELOPMENT.md, «المزامنة».
--
-- A local Gregorian day ('2026-10-15') like due_date. Set only with a due_date and never after
-- it; a task without one occupies its due day alone. The server enforces this in
-- src/data/schemas.ts (TaskInput) and src/data/mutations.ts (apps that predate the field).
ALTER TABLE tasks ADD COLUMN start_date TEXT;
