-- Imports through OAuth (Google Calendar, Microsoft To Do, Notion, Trello, Asana, TickTick).
-- See api/DEVELOPMENT.md, «الاستيراد بإذن OAuth», and src/imports/oauth.ts.
--
-- One row per started flow, from GET /v1/imports/oauth/:source/start until the provider returns
-- to the callback, which deletes it (single use), or until it expires (15 minutes; expired rows
-- are swept when a flow starts). Only the state's SHA-256 is kept: the state itself travels in
-- the provider's URLs. No token or code is ever stored: the access token goes in the job's first
-- queue message only, as with a pasted Todoist token (0006).
CREATE TABLE import_oauth_states (
  state_hash TEXT PRIMARY KEY, -- SHA-256 (hex) of the random state
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source TEXT NOT NULL, -- 'google-calendar', 'microsoft-todo', 'notion', 'trello', 'asana', 'ticktick-api'
  return_to TEXT NOT NULL, -- 'app' (zimam://import-callback) or a site origin from ALLOWED_ORIGINS
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX import_oauth_states_expiry ON import_oauth_states(expires_at);
