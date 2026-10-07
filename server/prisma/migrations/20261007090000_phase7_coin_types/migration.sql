-- Phase 7: the virtual-coin transaction taxonomy.
-- MySQL enums are altered in place, so widen first, remap legacy rows,
-- then narrow — no value is ever truncated away.

-- 1. Widen: legacy + target values coexist (additive, lossless).
ALTER TABLE `WalletTransaction`
  MODIFY `type` ENUM(
    'DEPOSIT',
    'WAGER',
    'PAYOUT',
    'DAILY_REWARD',
    'BONUS',
    'REFUND',
    'REGISTRATION_BONUS',
    'DAILY_LOGIN',
    'REWARDED_AD',
    'MATCH_REWARD',
    'PURCHASE',
    'COSMETIC_PURCHASE',
    'ROYAL_PASS_BONUS',
    'ADMIN_ADJUSTMENT'
  ) NOT NULL;

-- 2. Remap legacy rows to their Phase 7 equivalents.
UPDATE `WalletTransaction` SET `type` = 'DAILY_LOGIN' WHERE `type` = 'DAILY_REWARD';

-- 3. Narrow to the Phase 7 taxonomy.
ALTER TABLE `WalletTransaction`
  MODIFY `type` ENUM(
    'REGISTRATION_BONUS',
    'DAILY_LOGIN',
    'REWARDED_AD',
    'MATCH_REWARD',
    'PURCHASE',
    'COSMETIC_PURCHASE',
    'ROYAL_PASS_BONUS',
    'ADMIN_ADJUSTMENT'
  ) NOT NULL;
