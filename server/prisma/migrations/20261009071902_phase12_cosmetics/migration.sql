-- CreateTable
CREATE TABLE `Cosmetic` (
    `id` VARCHAR(191) NOT NULL,
    `key` VARCHAR(64) NOT NULL,
    `category` ENUM('BOARD_SKIN', 'PROFILE_PICTURE', 'PROFILE_FRAME', 'VICTORY_ANIMATION', 'CAPTURE_ANIMATION') NOT NULL,
    `name` VARCHAR(120) NOT NULL,
    `description` VARCHAR(255) NULL,
    `tier` ENUM('FREE', 'PREMIUM') NOT NULL DEFAULT 'FREE',
    `price` INTEGER NOT NULL DEFAULT 0,
    `grantedByDefault` BOOLEAN NOT NULL DEFAULT false,
    `sortOrder` INTEGER NOT NULL DEFAULT 0,
    `active` BOOLEAN NOT NULL DEFAULT true,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    UNIQUE INDEX `Cosmetic_key_key`(`key`),
    INDEX `Cosmetic_category_active_idx`(`category`, `active`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `UserCosmetic` (
    `id` VARCHAR(191) NOT NULL,
    `userId` VARCHAR(191) NOT NULL,
    `cosmeticId` VARCHAR(191) NOT NULL,
    `source` VARCHAR(16) NOT NULL DEFAULT 'claim',
    `equipped` BOOLEAN NOT NULL DEFAULT false,
    `grantedAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX `UserCosmetic_userId_equipped_idx`(`userId`, `equipped`),
    UNIQUE INDEX `UserCosmetic_userId_cosmeticId_key`(`userId`, `cosmeticId`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- AddForeignKey
ALTER TABLE `UserCosmetic` ADD CONSTRAINT `UserCosmetic_userId_fkey` FOREIGN KEY (`userId`) REFERENCES `User`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `UserCosmetic` ADD CONSTRAINT `UserCosmetic_cosmeticId_fkey` FOREIGN KEY (`cosmeticId`) REFERENCES `Cosmetic`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;
