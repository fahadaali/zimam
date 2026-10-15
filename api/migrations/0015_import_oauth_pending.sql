-- Imports through OAuth: the confirm step. See api/DEVELOPMENT.md, «الاستيراد بإذن OAuth», and
-- src/imports/oauth.ts.
--
-- The provider's callback no longer starts the import. It takes the state (0013), stores one row
-- here bound to the state's user and source, and returns to the client with a random `pending`
-- id; the signed-in client confirms with POST /v1/imports/oauth/confirm, and only the user who
-- started the flow can. So a provider link someone else started cannot pour another person's data
-- into their account: the person who consented is signed in as themselves, or not at all.
--
-- Only the pending id's SHA-256 is kept. A row lives 10 minutes and is used once: the confirm
-- sets used_at and clears code and code_verifier at once; used and expired rows are swept when a
-- flow starts, returns or is confirmed. The authorization code is useless without the client
-- secret (and the PKCE verifier); no access token is ever stored. Trello's token never comes
-- here: it goes to the client in the URL fragment and back in the confirm's body.
CREATE TABLE import_oauth_pending (
  pending_hash TEXT PRIMARY KEY, -- SHA-256 (hex) of the random pending id
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source TEXT NOT NULL, -- 'google-calendar', 'microsoft-todo', 'notion', 'trello', 'asana', 'ticktick-api'
  code TEXT, -- the provider's authorization code until the confirm; NULL for Trello
  code_verifier TEXT, -- the PKCE verifier (derived from the state) for the exchange; NULL without PKCE
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at INTEGER -- set by the confirm; the row then only answers 410 until it is swept
);
CREATE INDEX import_oauth_pending_expiry ON import_oauth_pending(expires_at);
