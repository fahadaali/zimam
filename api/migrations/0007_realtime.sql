-- Realtime sync: a WebSocket per device that only says "pull now" (src/realtime/).
-- See api/DEVELOPMENT.md, «المزامنة اللحظية».

-- Browsers cannot send an Authorization header when they open a WebSocket, so the web
-- app first trades its session for a ticket (POST /v1/realtime/ticket) and opens
-- /v1/realtime?ticket=… with it. A ticket works once and for 60 seconds; only its hash
-- is kept. It belongs to the session that asked for it, so signing out voids it.
CREATE TABLE realtime_tickets (
  ticket_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
CREATE INDEX realtime_tickets_expiry ON realtime_tickets(expires_at);
CREATE INDEX realtime_tickets_session ON realtime_tickets(session_hash);
