-- Phase 8 follow-up: index referenced by session-expiry sweeps
-- (declared as @@index([expiresAt]) in the schema).

CREATE INDEX `AdSession_expiresAt_idx` ON `AdSession`(`expiresAt`);
