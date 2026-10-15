-- AlterTable: optional tier for friend challenges (staked matches)
ALTER TABLE `Challenge` ADD COLUMN `tierId` VARCHAR(191) NULL;
