-- CreateTable: admin-managed game tiers (Phase 17). GameMatch.tierId
-- intentionally stays a snapshot string with no foreign key so edits
-- and disables never rewrite historical matches.
CREATE TABLE `Tier` (
    `id` VARCHAR(64) NOT NULL,
    `name` VARCHAR(64) NOT NULL,
    `gameKey` VARCHAR(64) NULL,
    `entryCostCoins` INTEGER NOT NULL DEFAULT 0,
    `rewardMultiplierBp` INTEGER NOT NULL DEFAULT 10000,
    `active` BOOLEAN NOT NULL DEFAULT true,
    `displayOrder` INTEGER NOT NULL DEFAULT 0,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    INDEX `Tier_active_displayOrder_idx`(`active`, `displayOrder`),
    INDEX `Tier_gameKey_active_idx`(`gameKey`, `active`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
