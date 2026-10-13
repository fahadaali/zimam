-- Project invites. The link carries a random code; only its SHA-256 hash is
-- stored, so a database leak does not expose working links. An invite is used
-- once, expires after 7 days, and can be revoked.

CREATE TABLE invites (
  code_hash TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('editor', 'viewer')),
  created_by TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  accepted_by TEXT REFERENCES users(id),
  accepted_at INTEGER,
  revoked_at INTEGER
);
CREATE INDEX invites_project ON invites(project_id, expires_at);
