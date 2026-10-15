-- Sign-in identities: each Sign in with Apple or Google account linked to a Zimam user.
--
-- A user may have several (Apple on the iPhone, Google on the web); sign-in finds the
-- user here by (provider, subject). A first sign-in whose verified email matches
-- exactly one user's verified identity joins that user (src/auth/identities.ts).
-- Apple private relay addresses never match. Deleting the account deletes its
-- identities, so the same Apple or Google account then starts a fresh one.
--
-- users.apple_sub stays (dropping its NOT NULL UNIQUE means rebuilding the table that
-- every other table references): it keeps the Apple subject of users created by Sign
-- in with Apple, a 'none:<id>' placeholder for users created by Google, and
-- 'deleted:<id>' once the account is deleted. Sign-in reads identities, and reads
-- apple_sub only to adopt a user the previous code created before its identity existed.
CREATE TABLE identities (
  provider TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  subject TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  email TEXT,
  -- 1 when the provider says it verified the address. Apple verifies every address it gives.
  email_verified INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (provider, subject)
);
CREATE INDEX identities_user ON identities(user_id);
CREATE INDEX identities_email ON identities(lower(email));

-- Every live user so far signed in with Apple, and Apple verified their addresses.
INSERT INTO identities (provider, subject, user_id, email, email_verified, created_at)
SELECT 'apple', apple_sub, id, email, CASE WHEN email IS NULL THEN 0 ELSE 1 END, created_at
FROM users WHERE apple_sub NOT LIKE 'deleted:%';
