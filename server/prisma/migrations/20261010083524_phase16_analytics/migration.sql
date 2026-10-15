-- CreateTable
CREATE TABLE `AnalyticsEvent` (
    `id` VARCHAR(191) NOT NULL,
    `type` ENUM('install', 'first_launch', 'registration', 'guest_conversion', 'session_start', 'session_end', 'match_completed', 'rematch', 'game_selected', 'ai_match_completed', 'friend_request', 'challenge_created', 'challenge_accepted', 'share', 'rewarded_ad_started', 'rewarded_ad_completed', 'interstitial_displayed', 'royal_pass_purchase', 'coin_purchase', 'cosmetic_purchase') NOT NULL,
    `userId` VARCHAR(191) NULL,
    `installId` VARCHAR(64) NULL,
    `sessionId` VARCHAR(64) NULL,
    `gameKey` VARCHAR(64) NULL,
    `platform` VARCHAR(32) NULL,
    `version` VARCHAR(32) NULL,
    `data` JSON NULL,
    `dedupeKey` VARCHAR(191) NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    UNIQUE INDEX `AnalyticsEvent_dedupeKey_key`(`dedupeKey`),
    INDEX `AnalyticsEvent_type_createdAt_idx`(`type`, `createdAt`),
    INDEX `AnalyticsEvent_userId_createdAt_idx`(`userId`, `createdAt`),
    INDEX `AnalyticsEvent_installId_createdAt_idx`(`installId`, `createdAt`),
    INDEX `AnalyticsEvent_sessionId_idx`(`sessionId`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `AnalyticsActiveDay` (
    `id` VARCHAR(191) NOT NULL,
    `subjectType` ENUM('INSTALL', 'USER') NOT NULL,
    `subjectId` VARCHAR(64) NOT NULL,
    `day` DATE NOT NULL,

    INDEX `AnalyticsActiveDay_subjectType_day_idx`(`subjectType`, `day`),
    UNIQUE INDEX `AnalyticsActiveDay_subjectType_subjectId_day_key`(`subjectType`, `subjectId`, `day`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- AddForeignKey
ALTER TABLE `AnalyticsEvent` ADD CONSTRAINT `AnalyticsEvent_userId_fkey` FOREIGN KEY (`userId`) REFERENCES `User`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;
