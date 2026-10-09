-- CreateTable
CREATE TABLE `Purchase` (
    `id` VARCHAR(191) NOT NULL,
    `userId` VARCHAR(191) NOT NULL,
    `productKey` VARCHAR(128) NOT NULL,
    `platform` ENUM('GOOGLE_PLAY', 'APPLE_APP_STORE') NOT NULL,
    `purchaseToken` VARCHAR(191) NOT NULL,
    `orderId` VARCHAR(128) NULL,
    `state` ENUM('PENDING', 'GRANTED', 'REFUNDED', 'REVOKED', 'EXPIRED') NOT NULL DEFAULT 'PENDING',
    `coinAmount` INTEGER NOT NULL DEFAULT 0,
    `passDays` INTEGER NOT NULL DEFAULT 0,
    `entitlementPreviousExpiresAt` DATETIME(3) NULL,
    `entitlementExpiresAt` DATETIME(3) NULL,
    `verifiedAt` DATETIME(3) NULL,
    `grantedAt` DATETIME(3) NULL,
    `revokedAt` DATETIME(3) NULL,
    `revocationReason` VARCHAR(64) NULL,
    `rawVerification` JSON NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    INDEX `Purchase_userId_createdAt_idx`(`userId`, `createdAt`),
    INDEX `Purchase_state_createdAt_idx`(`state`, `createdAt`),
    UNIQUE INDEX `Purchase_platform_purchaseToken_key`(`platform`, `purchaseToken`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `DevStorePurchase` (
    `id` VARCHAR(191) NOT NULL,
    `purchaseToken` VARCHAR(191) NOT NULL,
    `orderId` VARCHAR(191) NOT NULL,
    `productKey` VARCHAR(128) NOT NULL,
    `userId` VARCHAR(191) NOT NULL,
    `state` ENUM('PENDING', 'PURCHASED', 'CANCELED') NOT NULL DEFAULT 'PURCHASED',
    `issuedAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    UNIQUE INDEX `DevStorePurchase_purchaseToken_key`(`purchaseToken`),
    UNIQUE INDEX `DevStorePurchase_orderId_key`(`orderId`),
    INDEX `DevStorePurchase_userId_issuedAt_idx`(`userId`, `issuedAt`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- AddForeignKey
ALTER TABLE `Purchase` ADD CONSTRAINT `Purchase_userId_fkey` FOREIGN KEY (`userId`) REFERENCES `User`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;
