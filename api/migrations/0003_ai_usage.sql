-- In-app assistant usage per user per calendar month (UTC), for the monthly
-- request limit and for subscription accounting. Only counts are stored, never
-- the text sent to the model.

CREATE TABLE ai_usage (
  user_id TEXT NOT NULL REFERENCES users(id),
  month TEXT NOT NULL, -- 'YYYY-MM'
  requests INTEGER NOT NULL DEFAULT 0,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, month)
);
