-- «زمام الاحترافية»: the billing grace period. See api/DEVELOPMENT.md, «الاشتراكات».
--
-- When a renewal fails, Apple keeps trying to charge (billing retry) and, with Billing Grace
-- Period on in App Store Connect, the subscriber keeps access until gracePeriodExpiresDate.
-- The server reads it from the App Store Server API (GET /inApps/v1/subscriptions/{id},
-- signedRenewalInfo) when a transaction has expired and on DID_FAIL_TO_RENEW and
-- GRACE_PERIOD_EXPIRED. A row is pro while MAX(expires_at, grace_expires_at) is in the
-- future and it is not revoked. Every update rewrites the three columns, so a renewal clears them.
ALTER TABLE entitlements ADD COLUMN grace_expires_at INTEGER; -- ms; set only while Apple retries the payment in the grace period
ALTER TABLE entitlements ADD COLUMN billing_retry INTEGER NOT NULL DEFAULT 0; -- 1 while Apple retries the payment (isInBillingRetryPeriod)
ALTER TABLE entitlements ADD COLUMN expiration_intent INTEGER; -- Apple's expirationIntent: 1 cancelled, 2 billing error, ...
