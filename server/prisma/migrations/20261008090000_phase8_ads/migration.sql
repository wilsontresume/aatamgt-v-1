-- Phase 8: ad architecture — royal pass flag, rewarded ad sessions
-- (server-minted, redeem-once) and interstitial show records.

-- AlterTable
ALTER TABLE `User` ADD COLUMN `royalPassExpiresAt` DATETIME(3) NULL;

-- CreateTable
CREATE TABLE `AdSession` (
    `id` VARCHAR(191) NOT NULL,
    `userId` VARCHAR(191) NOT NULL,
    `provider` VARCHAR(32) NOT NULL,
    `tier` VARCHAR(16) NOT NULL,
    `nonce` VARCHAR(64) NOT NULL,
    `status` ENUM('OPEN', 'REDEEMED') NOT NULL DEFAULT 'OPEN',
    `expiresAt` DATETIME(3) NOT NULL,
    `redeemedAt` DATETIME(3) NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX `AdSession_userId_createdAt_idx`(`userId`, `createdAt`),
    UNIQUE INDEX `AdSession_nonce_key`(`nonce`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `AdShow` (
    `id` VARCHAR(191) NOT NULL,
    `userId` VARCHAR(191) NOT NULL,
    `kind` VARCHAR(16) NOT NULL,
    `matchId` VARCHAR(64) NULL,
    `shownAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX `AdShow_userId_kind_shownAt_idx`(`userId`, `kind`, `shownAt`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- AddForeignKey
ALTER TABLE `AdSession` ADD CONSTRAINT `AdSession_userId_fkey` FOREIGN KEY (`userId`) REFERENCES `User`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `AdShow` ADD CONSTRAINT `AdShow_userId_fkey` FOREIGN KEY (`userId`) REFERENCES `User`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;
