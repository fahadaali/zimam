-- The account's photo («صورة العرض»): the file is in the ATTACHMENTS bucket under avatars/<user id>
-- (src/routes/me.ts). This is when it last changed, so apps fetch it again only then; NULL has none.
ALTER TABLE users ADD COLUMN avatar_updated_at INTEGER;
