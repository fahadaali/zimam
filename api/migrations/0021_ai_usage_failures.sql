-- Assistant requests that failed after the model was paid for: it refused, was cut off, or gave
-- an answer that does not hold up (src/routes/assistant.ts). They are given back to the month's
-- quota, so they do not cost the user, but counted here; once they reach the month's limit the
-- month is closed too, so input that makes every answer fail cannot buy unlimited model calls.
-- See api/DEVELOPMENT.md, «الحصة».
ALTER TABLE ai_usage ADD COLUMN failed_requests INTEGER NOT NULL DEFAULT 0;
