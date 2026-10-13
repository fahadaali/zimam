-- Account lifecycle.
--
-- Sign in with Apple: the refresh token Apple returns for the app's
-- authorization code, and the client id (bundle id or web Services ID) it was
-- issued to. Deleting the account revokes it with Apple (App Store guideline
-- 5.1.1(v)) and clears both columns.
ALTER TABLE users ADD COLUMN apple_refresh_token TEXT;
ALTER TABLE users ADD COLUMN apple_client_id TEXT;

-- Invites get a public id so the owner can revoke one; the code itself is
-- never stored. Existing invites get a random UUID-shaped id.
ALTER TABLE invites ADD COLUMN id TEXT;
UPDATE invites SET id = lower(
  hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' ||
  substr('89ab', 1 + abs(random()) % 4, 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6))
) WHERE id IS NULL;
CREATE UNIQUE INDEX invites_id ON invites(id);
