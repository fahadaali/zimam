-- How far each device's local notifications reach (PATCH /v1/devices/:token). iOS keeps 64
-- pending local notifications, so the app can drop the latest reminders of its 14-day window
-- when it has more; it reports the last fire time it did schedule, in Unix ms, after each pull.
-- NULL: the whole window (an app that does not report, or one whose window fit). Reset to NULL
-- when a registration is new or moves to another session. The cron pushes a reminder past it
-- (src/push/reminders.ts). See api/DEVELOPMENT.md, «القاعدة: متى يرسل الخادم».
ALTER TABLE devices ADD COLUMN scheduled_through INTEGER;
