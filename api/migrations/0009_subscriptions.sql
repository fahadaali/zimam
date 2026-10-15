-- «زمام الاحترافية»: App Store subscriptions. See api/DEVELOPMENT.md, «الاشتراكات».
--
-- One row per subscription (its original transaction): renewals, upgrades within the
-- group, expiry and refunds update the same row. The row holds the latest transaction
-- the server fetched from the App Store Server API, never what a client or a
-- notification claimed. The user is the one whose id the app set as appAccountToken
-- at purchase. Deleting the account deletes its rows; the subscription itself lives
-- with Apple, and the user cancels it in their Apple account settings.
CREATE TABLE entitlements (
  original_transaction_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id TEXT NOT NULL, -- 'app.zimam.ios.pro.monthly' or 'app.zimam.ios.pro.yearly'
  transaction_id TEXT NOT NULL, -- the latest transaction applied
  purchased_at INTEGER NOT NULL, -- that transaction's purchaseDate (ms)
  expires_at INTEGER, -- its expiresDate (ms); pro while in the future and not revoked
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  status TEXT NOT NULL CHECK (status IN ('active', 'expired', 'revoked')), -- when last updated
  revoked_at INTEGER, -- refunded or revoked by Apple (revocationDate, ms)
  updated_at INTEGER NOT NULL
);
CREATE INDEX entitlements_user ON entitlements(user_id, expires_at);
