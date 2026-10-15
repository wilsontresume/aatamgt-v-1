-- AlterTable: tier preserved on every match configuration
ALTER TABLE `GameMatch` ADD COLUMN `tierId` VARCHAR(191) NULL;

-- AlterTable: AI seats without a fake User row; userId becomes optional
ALTER TABLE `MatchPlayer` MODIFY `userId` VARCHAR(191) NULL;
ALTER TABLE `MatchPlayer` ADD COLUMN `isAi` BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE `MatchPlayer` ADD COLUMN `aiName` VARCHAR(191) NULL;

-- AlterTable: AI moves carry a matchPlayerId instead of a userId
ALTER TABLE `MatchMove` MODIFY `userId` VARCHAR(191) NULL;

-- CreateTable
CREATE TABLE `MatchmakingTicket` (
    `id` VARCHAR(191) NOT NULL,
    `userId` VARCHAR(191) NOT NULL,
    `gameKey` VARCHAR(191) NOT NULL,
    `tierId` VARCHAR(191) NOT NULL,
    `status` ENUM('WAITING', 'MATCHED', 'CANCELLED', 'EXPIRED') NOT NULL DEFAULT 'WAITING',
    `matchedMatchId` VARCHAR(191) NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    INDEX `MatchmakingTicket_gameKey_tierId_status_idx`(`gameKey`, `tierId`, `status`),
    INDEX `MatchmakingTicket_userId_status_idx`(`userId`, `status`),
    INDEX `MatchmakingTicket_status_createdAt_idx`(`status`, `createdAt`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- AddForeignKey
ALTER TABLE `MatchmakingTicket` ADD CONSTRAINT `MatchmakingTicket_userId_fkey` FOREIGN KEY (`userId`) REFERENCES `User`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;
