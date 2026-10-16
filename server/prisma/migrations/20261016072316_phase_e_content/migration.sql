-- AlterTable
ALTER TABLE `Game` ADD COLUMN `displayOrder` INTEGER NOT NULL DEFAULT 0;

-- AlterTable
ALTER TABLE `GameMatch` ADD COLUMN `rewardMultiplierBp` INTEGER NULL;

-- AlterTable
ALTER TABLE `Tier` ADD COLUMN `artAssetId` VARCHAR(64) NULL,
    ADD COLUMN `description` VARCHAR(255) NULL,
    ADD COLUMN `displayColor` VARCHAR(32) NULL;

-- CreateTable
CREATE TABLE `GameAsset` (
    `id` VARCHAR(191) NOT NULL,
    `gameKey` VARCHAR(64) NULL,
    `type` ENUM('HOME_BACKGROUND', 'GAME_BACKGROUND', 'GAME_CARD', 'GAME_ICON', 'BOARD_TEXTURE', 'BOARD_BACKGROUND', 'PIECE_ART', 'TIER_ART', 'BANNER', 'DECORATION') NOT NULL,
    `storageKey` VARCHAR(191) NOT NULL,
    `originalName` VARCHAR(255) NOT NULL,
    `mimeType` VARCHAR(64) NOT NULL,
    `byteSize` INTEGER NOT NULL,
    `width` INTEGER NULL,
    `height` INTEGER NULL,
    `checksum` VARCHAR(64) NOT NULL,
    `active` BOOLEAN NOT NULL DEFAULT true,
    `version` INTEGER NOT NULL DEFAULT 1,
    `lineageId` VARCHAR(64) NOT NULL,
    `note` VARCHAR(255) NULL,
    `createdByUserId` VARCHAR(64) NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    UNIQUE INDEX `GameAsset_storageKey_key`(`storageKey`),
    INDEX `GameAsset_gameKey_type_active_idx`(`gameKey`, `type`, `active`),
    INDEX `GameAsset_lineageId_version_idx`(`lineageId`, `version`),
    INDEX `GameAsset_type_active_idx`(`type`, `active`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `ContentPublication` (
    `id` VARCHAR(191) NOT NULL,
    `version` INTEGER NOT NULL,
    `status` ENUM('PUBLISHED', 'SUPERSEDED') NOT NULL DEFAULT 'PUBLISHED',
    `manifest` JSON NOT NULL,
    `checksum` VARCHAR(64) NOT NULL,
    `note` VARCHAR(255) NULL,
    `rolledBackFrom` INTEGER NULL,
    `publishedByUserId` VARCHAR(64) NULL,
    `publishedByName` VARCHAR(64) NOT NULL DEFAULT 'system',
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    UNIQUE INDEX `ContentPublication_version_key`(`version`),
    INDEX `ContentPublication_status_version_idx`(`status`, `version`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
