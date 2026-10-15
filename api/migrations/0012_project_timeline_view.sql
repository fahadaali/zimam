-- «المخطط الزمني» as a project view: projects.view gains 'timeline' beside 'list', 'kanban'
-- and 'calendar'. See api/DEVELOPMENT.md, «المزامنة».
--
-- SQLite cannot change a CHECK constraint, so the table is rebuilt. Dropping the old table
-- deletes its rows first, which would cascade to project_members and invites (ON DELETE
-- CASCADE) and trip sections' plain reference. So: foreign keys are checked at the end of the
-- migration only, the two cascading tables are copied aside and put back after the rename, and
-- every id stays the same. Nothing else references projects (tasks, attachments and changes
-- keep project_id without a foreign key).
PRAGMA defer_foreign_keys = true;

CREATE TABLE project_members_keep AS SELECT * FROM project_members;
CREATE TABLE invites_keep AS SELECT * FROM invites;

CREATE TABLE projects_next (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES users(id),
  parent_id TEXT,
  kind TEXT NOT NULL DEFAULT 'project' CHECK (kind IN ('project', 'folder')),
  name TEXT NOT NULL,
  view TEXT NOT NULL DEFAULT 'list' CHECK (view IN ('list', 'kanban', 'calendar', 'timeline')),
  sort_order REAL NOT NULL DEFAULT 0,
  archived_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
INSERT INTO projects_next (id, owner_id, parent_id, kind, name, view, sort_order, archived_at, created_at, updated_at, deleted_at)
  SELECT id, owner_id, parent_id, kind, name, view, sort_order, archived_at, created_at, updated_at, deleted_at FROM projects;

DROP TABLE projects;
ALTER TABLE projects_next RENAME TO projects;

DELETE FROM project_members;
INSERT INTO project_members SELECT * FROM project_members_keep;
DROP TABLE project_members_keep;

DELETE FROM invites;
INSERT INTO invites SELECT * FROM invites_keep;
DROP TABLE invites_keep;

PRAGMA defer_foreign_keys = false;
