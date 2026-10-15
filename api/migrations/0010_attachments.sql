-- Task attachments: files kept in the R2 bucket zimam-attachments (binding ATTACHMENTS).
-- See api/DEVELOPMENT.md, «المرفقات».
--
-- One row per file. Who may see an attachment follows its task (the task's project, or the
-- inbox owner); project_id is the task's project, kept in step when the task moves. Rows are
-- soft-deleted (deleted_at) so sync can tell clients, with a change row (entity 'attachment')
-- for the task's audience. The object in R2 goes right away when an attachment is deleted
-- directly, otherwise on the next cron run; r2_key is then NULL. The file name is cleared
-- from the tombstones of a deleted account.
CREATE TABLE attachments (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  project_id TEXT, -- the task's project, NULL for an inbox task
  user_id TEXT NOT NULL REFERENCES users(id), -- the uploader
  file_name TEXT NOT NULL,
  content_type TEXT NOT NULL, -- set by the server from the extension, never the client's
  size INTEGER NOT NULL, -- bytes
  r2_key TEXT, -- the object in R2; NULL once removed
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE INDEX attachments_task ON attachments(task_id);
-- The uploader's storage quota counts their live attachments.
CREATE INDEX attachments_user ON attachments(user_id) WHERE deleted_at IS NULL;
-- Objects still in R2 after their row was deleted, for the cron to remove.
CREATE INDEX attachments_purge ON attachments(deleted_at) WHERE deleted_at IS NOT NULL AND r2_key IS NOT NULL;
