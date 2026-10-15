import { Module } from '@nestjs/common';
import { ChallengesController } from './challenges.controller';
import { ChallengesService } from './challenges.service';
import { GamesModule } from '../games/games.module';
import { MatchesModule } from '../matches/matches.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { AnalyticsModule } from '../analytics/analytics.module';
import { TiersModule } from '../matchmaking/tiers.module';
import { WalletModule } from '../wallet/wallet.module';

@Module({
  imports: [
    GamesModule,
    MatchesModule,
    NotificationsModule,
    AnalyticsModule,
    TiersModule,
    WalletModule,
  ],
  controllers: [ChallengesController],
  providers: [ChallengesService],
  exports: [ChallengesService],
})
export class ChallengesModule {}
