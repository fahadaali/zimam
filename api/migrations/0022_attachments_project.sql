-- The project owner's storage quota also counts the files left on their projects by members who
-- no longer see them (src/attachments.ts, storageUsed). See api/DEVELOPMENT.md, «المرفقات».
CREATE INDEX attachments_project ON attachments(project_id) WHERE deleted_at IS NULL;
